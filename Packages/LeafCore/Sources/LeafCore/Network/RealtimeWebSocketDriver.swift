//
//  RealtimeWebSocketDriver.swift
//  LeafCore
//
//  Track 5 / S7 — Phase D.2 + D.3 + D.4 + D.5 + D.6. Phoenix Channels protocol
//  implementation wrapping URLSessionWebSocketTask. Owns:
//    • WS lifecycle (connect / disconnect / suspend / resume)
//    • Phoenix message ref counter (monotonic per connection)
//    • Channel join state (single workspace channel at a time)
//    • Dispatch from postgres_changes → typed RealtimeEvent AsyncStream
//    • Heartbeat loop (D.5 — 30s tick, 3 missed → reconnect)
//    • Reconnect loop with exponential backoff 1/2/4/8/16s (D.6)
//
//  Downstream consumer (Phase D.5+, LeafRealtimeService) reads the `events`
//  stream, resolves teamKey by keyID, decrypts, and routes to:
//    • DirectMessageInboxService.absorbRealtimePush(_:)
//    • TeamEventMirrorService.absorbRealtimePush(_:)
//
//  Test seams:
//    • `URLSessionWebSocketTaskProtocol` — mockable WS task
//    • `taskFactory` closure — inject mock factory in tests
//    • `heartbeatIntervalSec` / `reconnectBaseDelayMs` — injectable timings
//      (tests use sub-second values to keep suite fast)
//    • State exposed via async getter for assertion
//

import Foundation

// MARK: - URLSessionWebSocketTaskProtocol (test seam)

/// Protocol abstracting `URLSessionWebSocketTask` for test injection.
/// URLSessionWebSocketTask conforms by default (extension at bottom).
public protocol URLSessionWebSocketTaskProtocol: AnyObject, Sendable {
    func resume()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
}

extension URLSessionWebSocketTask: URLSessionWebSocketTaskProtocol {}

// MARK: - RealtimeWebSocketDriver

public actor RealtimeWebSocketDriver {

    public enum State: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        case reconnecting(attempt: Int)
        case suspended

        /// True when the driver should attempt to read from the WS task.
        var isActive: Bool {
            switch self {
            case .connected, .reconnecting: return true
            default: return false
            }
        }
    }

    // MARK: - Public surface

    public private(set) var state: State = .disconnected

    /// AsyncStream of dispatched events. nonisolated so consumers can iterate
    /// outside the actor without hop overhead.
    public nonisolated let events: AsyncStream<RealtimeEvent>

    // MARK: - Tunables (injectable for test determinism)

    /// Heartbeat tick interval — Supabase Realtime convention (30s in prod).
    /// Tests inject sub-second values to keep suites fast.
    private let heartbeatIntervalSec: TimeInterval
    /// Missed heartbeats threshold before assuming the server is dead and
    /// triggering reconnect.
    private let missingHeartbeatLimit: Int
    /// Initial reconnect delay — backoff schedule is 1×, 2×, 4×, 8×, 16× of this.
    private let reconnectBaseDelayMs: Int64
    /// Cap on reconnect delay (steady-state after 5th attempt).
    private let reconnectMaxDelayMs: Int64
    /// Hard cap on reconnect attempts before the driver transitions to
    /// `.disconnected` terminal. Prevents (a) battery drain on permanent
    /// server-down, (b) the reconnect loop running forever with no UX
    /// indicator past `.reconnecting(attempt:)`. Set to 0 = unbounded
    /// (back-compat for tests that need to observe many attempts).
    private let maxReconnectAttempts: Int
    /// ± jitter factor multiplied onto each backoff delay so a fleet of
    /// clients that simultaneously dropped (DO restart, project redeploy)
    /// doesn't thunder back on the exact wallclock grid. `0` = deterministic
    /// schedule (tests pin via `delayForReconnectAttempt`).
    private let reconnectJitterFraction: Double

    // MARK: - Private state

    private let eventContinuation: AsyncStream<RealtimeEvent>.Continuation
    private let taskFactory: @Sendable (URLRequest) -> URLSessionWebSocketTaskProtocol

    private var refCounter: Int = 0
    private var wsTask: (any URLSessionWebSocketTaskProtocol)?
    private var receiveLoopTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    /// Number of heartbeat frames sent without a matching `phx_reply`. Reset on
    /// any heartbeat reply from topic="phoenix". Three or more triggers reconnect.
    private var missedHeartbeats: Int = 0

    /// Topic of the currently-joined channel (single channel at a time in S7).
    private var currentChannelTopic: String?

    /// Workspace ID of the currently-joined channel. Captured on phx_join so
    /// that reconnect attempts can re-issue the same join. Mirrors
    /// `currentChannelTopic` but avoids re-parsing the topic string.
    private var currentChannelWorkspaceID: String?

    /// Last URL passed to `connect(url:jwt:)`. Captured so the reconnect loop
    /// can replay the connection without external coordination.
    private var lastConnectURL: URL?
    /// Last JWT passed to `connect(url:jwt:)`. Same purpose as `lastConnectURL`.
    /// Used both for WS replay and for the phx_join `access_token` payload.
    /// Also rotated in-place by `refreshAccessToken(_:)` so reconnect cycles
    /// pick up the fresh token without a separate connect() round-trip.
    private var lastConnectJWT: String?

    /// Service-injected closure invoked before each reconnect attempt to
    /// supply a fresh JWT. Returning nil = caller couldn't refresh; the
    /// driver falls back to `lastConnectJWT`. Set via `setJWTProvider(_:)`
    /// from `LeafRealtimeService` — driver does NOT import SupabaseClient
    /// (closes A-I3 carry-over without an actor-import cycle).
    private var jwtProvider: (@Sendable () async -> String?)?

    // MARK: - Init

    public init(
        taskFactory: @escaping @Sendable (URLRequest) -> URLSessionWebSocketTaskProtocol = { request in
            URLSession.shared.webSocketTask(with: request)
        },
        heartbeatIntervalSec: TimeInterval = 30,
        missingHeartbeatLimit: Int = 3,
        reconnectBaseDelayMs: Int64 = 1_000,
        reconnectMaxDelayMs: Int64 = 16_000,
        maxReconnectAttempts: Int = 20,
        reconnectJitterFraction: Double = 0.5,
        jwtProvider: (@Sendable () async -> String?)? = nil
    ) {
        var continuationCapture: AsyncStream<RealtimeEvent>.Continuation!
        self.events = AsyncStream { continuation in
            continuationCapture = continuation
        }
        self.eventContinuation = continuationCapture
        self.taskFactory = taskFactory
        self.heartbeatIntervalSec = heartbeatIntervalSec
        self.missingHeartbeatLimit = missingHeartbeatLimit
        self.reconnectBaseDelayMs = reconnectBaseDelayMs
        self.reconnectMaxDelayMs = reconnectMaxDelayMs
        self.maxReconnectAttempts = max(0, maxReconnectAttempts)
        self.reconnectJitterFraction = max(0, reconnectJitterFraction)
        // P1 re-dispatch — Important-2 race fix. Install the provider at init
        // time so the actor has it immediately, no async install Task → no
        // race window where a transport-level reconnect could fire before
        // `setJWTProvider` arrived.
        self.jwtProvider = jwtProvider
    }

    // MARK: - Connect

    /// Open a WebSocket to the Supabase Realtime endpoint.
    /// URL: `wss://<project>.supabase.co/realtime/v1/websocket?apikey=<anon>&vsn=1.0.0`
    ///
    /// Idempotent: a second call while already `.connected` is a no-op.
    /// Auth is carried inside the phx_join payload (D.3), NOT on the WS upgrade
    /// header. The JWT is captured here purely for symmetry with the spec; if
    /// you call `connect` then `joinWorkspaceChannel`, the join is what auths.
    public func connect(url: URL, jwt: String) async throws {
        if state == .connected || state == .connecting { return }

        // Stop any prior reconnect attempt (e.g., user called disconnect()
        // then connect() before backoff fired).
        reconnectTask?.cancel()
        reconnectTask = nil

        lastConnectURL = url
        lastConnectJWT = jwt
        state = .connecting

        let request = URLRequest(url: url)
        let task = taskFactory(request)
        wsTask = task
        task.resume()

        // Transition to `.connected` happens optimistically here — URLSessionWebSocketTask
        // does not expose an "open" callback. Real connectivity is confirmed when phx_join
        // ack arrives (D.3). On WS upgrade failure, the first `receive()` throws and the
        // loop routes via handleConnectionLoss → reconnect.
        state = .connected
        missedHeartbeats = 0

        // Start receive loop. Captured `task` reference is the same one we just
        // stored in `wsTask`; weak self avoids retention through the loop.
        receiveLoopTask = Task { [weak self] in
            await self?.receiveLoop()
        }

        // D.5 — start heartbeat once we believe we're connected.
        startHeartbeat()
    }

    // MARK: - Disconnect

    /// Gracefully close the WS — no auto-reconnect attempt. Idempotent.
    public func disconnect() async {
        stopHeartbeat()
        stopReconnectLoop()
        wsTask?.cancel(with: .normalClosure, reason: nil)
        wsTask = nil
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        currentChannelTopic = nil
        currentChannelWorkspaceID = nil
        state = .disconnected
    }

    // MARK: - Suspend / Resume (D.6 — driver-level primitive)

    /// Pause the driver — stops heartbeat + reconnect, closes the WS. State
    /// stays `.suspended` until `resume()` is called. Used when the app moves
    /// to background or the user toggles "Pause team sync" in Settings.
    /// Idempotent (calling while already suspended is a no-op).
    public func suspend() async {
        guard state != .suspended else { return }
        stopHeartbeat()
        stopReconnectLoop()
        wsTask?.cancel(with: .normalClosure, reason: nil)
        wsTask = nil
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        // Preserve currentChannelTopic / WorkspaceID — they're needed if
        // resume() reconnects and wants to re-join the same channel.
        state = .suspended
    }

    /// Wake the driver from suspended state. Replays the captured URL + JWT
    /// via connect(); if a channel was joined pre-suspend, the reconnect
    /// machinery (D.6) will re-join it.
    /// Throws `.notConnected` if no prior connect() has happened (nothing to replay).
    public func resume() async throws {
        guard state == .suspended else { return }
        guard let url = lastConnectURL, let jwt = lastConnectJWT else {
            throw RealtimeError.notConnected
        }
        state = .disconnected
        try await connect(url: url, jwt: jwt)
    }

    // MARK: - Phoenix channel — join / leave

    /// Send a `phx_join` frame for the workspace channel with 3 postgres_changes
    /// subscriptions (INSERT team_events / INSERT direct_messages / UPDATE direct_messages).
    ///
    /// Topic: `realtime:leaf-workspace-<workspaceID>` (lowercase wid).
    /// Filter: `workspace_id=eq.<workspaceID>` — server-side RLS additionally enforces.
    ///
    /// Returns immediately after the frame is sent; channel-join ack is dispatched
    /// asynchronously via the events stream as `.channelJoined` / `.channelRejected`.
    /// Throws `.notConnected` if WS isn't open.
    public func joinWorkspaceChannel(workspaceID: String, accessToken: String) async throws {
        guard state == .connected, let task = wsTask else {
            throw RealtimeError.notConnected
        }
        let ref = nextRef()
        let frame = try RealtimePhoenixFrame.phxJoin(
            workspaceID: workspaceID,
            accessToken: accessToken,
            ref: ref
        )
        do {
            try await task.send(.string(frame))
        } catch {
            throw RealtimeError.encodingFailed(reason: "send phx_join: \(error)")
        }
        // Remember workspaceID so reconnect can re-issue join.
        currentChannelWorkspaceID = workspaceID
    }

    /// Rotate the access_token in place on the currently-joined channel.
    /// Sends a Phoenix `access_token` frame on `currentChannelTopic`.
    ///
    /// In-place rotation matters: a reconnect-driven refresh would tear the
    /// WS down and start a backoff cycle (1/2/4/8/16s). Long-running Macs hit
    /// JWT TTL every ~60min; without this in-place path, every TTL expiry
    /// would silently reject phx_join on reconnect → reconnect storm.
    ///
    /// Updates `lastConnectJWT` so subsequent reconnect attempts (which DO
    /// replay `lastConnectJWT` via `phx_join`) carry the rotated value.
    ///
    /// Silent no-op when no channel is currently joined (driver disconnected
    /// or never joined). Caller is `LeafRealtimeService.refreshIfNeeded()`.
    ///
    /// Throws on send failure (network blip mid-rotation). Service-layer
    /// caller swallows the error and retries on the next tick.
    public func refreshAccessToken(_ accessToken: String) async throws {
        // Always capture the rotated token so future reconnect cycles use it.
        lastConnectJWT = accessToken
        // Send the in-place rotation frame only if we have a joined channel.
        // No channel → no-op; the captured `lastConnectJWT` covers the next
        // connect/join cycle anyway.
        guard let topic = currentChannelTopic, let task = wsTask else { return }
        let ref = nextRef()
        let frame = try RealtimePhoenixFrame.accessTokenRefresh(
            topic: topic,
            accessToken: accessToken,
            ref: ref
        )
        try await task.send(.string(frame))
    }

    /// Send a `phx_leave` for the currently-joined channel (no-op if none).
    /// Best-effort: errors are swallowed (we're tearing the channel down anyway).
    public func leaveCurrentChannel() async {
        guard let topic = currentChannelTopic else { return }
        let ref = nextRef()
        if let frame = try? RealtimePhoenixFrame.phxLeave(topic: topic, ref: ref),
           let task = wsTask {
            try? await task.send(.string(frame))
        }
        currentChannelTopic = nil
        currentChannelWorkspaceID = nil
    }

    /// Test-only inspector for the currently-joined channel topic.
    /// Production callers don't need this; the driver-internal state is the
    /// authoritative source of truth.
    public func currentTopic() -> String? { currentChannelTopic }

    /// Test-only inspector for the current missed-heartbeat counter.
    /// Production has no use for the raw count — it only acts on the threshold.
    public func currentMissedHeartbeats() -> Int { missedHeartbeats }

    /// Install (or clear) the pre-reconnect JWT provider closure.
    /// `LeafRealtimeService` calls this once at composition to wire in its
    /// `SupabaseClient.ensureFreshSession()` path. The closure is invoked
    /// before each `attemptReconnect()` so a long-running session always
    /// reconnects with a non-expired JWT. nil disables the hook.
    ///
    /// P1 re-dispatch — prefer the init-time `jwtProvider:` parameter for
    /// production wiring (zero race window). This method exists for legacy
    /// callers + future programmatic replacement (e.g., closure swap on
    /// re-auth).
    public func setJWTProvider(_ provider: (@Sendable () async -> String?)?) {
        self.jwtProvider = provider
    }

    #if DEBUG
    /// Test-only inspector for the captured lastConnectJWT.
    /// Production has no use for the raw value — it is only used internally
    /// for phx_join replay during reconnect.
    public func currentConnectJWT() -> String? { lastConnectJWT }

    /// Test-only inspector — was the jwtProvider closure registered?
    /// Used by the P1 re-dispatch race-fix test to confirm init-time install
    /// (no fire-and-forget Task hop).
    public func hasJWTProviderForTest() -> Bool { jwtProvider != nil }
    #endif

    // MARK: - Receive loop + dispatch

    private func receiveLoop() async {
        while !Task.isCancelled, state.isActive, let task = wsTask {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                // WS closed / error — route through reconnect machinery (D.6).
                // handleConnectionLoss takes care of state transition + reconnect.
                await handleConnectionLoss(reason: "receive: \(error)")
                return
            }
            dispatchMessage(message)
        }
    }

    /// Inspect a single received WS frame and yield the appropriate RealtimeEvent.
    /// Public for testability: tests inject WS Text frames and assert the yielded
    /// events match. In production this is only called from `receiveLoop`.
    public func dispatchMessage(_ message: URLSessionWebSocketTask.Message) {
        let json: String
        switch message {
        case .string(let s):
            json = s
        case .data(let d):
            // Phoenix v2 over Supabase Realtime is Text frames only; binary would
            // be a protocol violation — skip silently.
            guard let s = String(data: d, encoding: .utf8) else { return }
            json = s
        @unknown default:
            return
        }
        guard let parsed = RealtimePhoenixMessage.parse(json) else { return }
        switch parsed.event {
        case "phx_reply":
            handlePhxReply(parsed)
        case "postgres_changes":
            handlePostgresChanges(parsed)
        case "phx_close":
            eventContinuation.yield(.disconnected(reason: "phx_close"))
            state = .disconnected
            currentChannelTopic = nil
            currentChannelWorkspaceID = nil
        case "phx_error":
            // Server-side channel error (e.g., RLS denied mid-stream). Treat as
            // a disconnect; reconnect loop (D.6) decides whether to retry.
            eventContinuation.yield(.disconnected(reason: "phx_error"))
            currentChannelTopic = nil
            currentChannelWorkspaceID = nil
        default:
            // presence_diff, etc. — future phases.
            break
        }
    }

    // MARK: - phx_reply dispatch

    private func handlePhxReply(_ msg: RealtimePhoenixMessage) {
        let response = msg.payload["response"] as? [String: Any] ?? [:]
        // Phoenix payload shape for phx_reply:
        //   { "status": "ok" | "error", "response": { ... } }
        let status = (msg.payload["status"] as? String) ?? ""
        if status == "ok" {
            // Heartbeat reply — server alive, reset missed counter. Heartbeats
            // are sent on topic="phoenix" (not the workspace channel), so
            // dispatch on topic first to avoid emitting channelJoined for them.
            if msg.topic == "phoenix" {
                missedHeartbeats = 0
                return
            }
            // First phx_reply on a workspace topic → it's the phx_join ack.
            // We don't track per-ref state in S7 (single channel at a time).
            if msg.topic.hasPrefix("realtime:leaf-workspace-") {
                currentChannelTopic = msg.topic
                eventContinuation.yield(.channelJoined(topic: msg.topic))
            }
            // Other status:"ok" replies are silent.
        } else {
            // Pull reason out of either {response: {reason: ...}} or {response: {error: ...}}.
            let reason = (response["reason"] as? String)
                ?? (response["error"] as? String)
                ?? "unknown"
            if msg.topic.hasPrefix("realtime:leaf-workspace-") {
                eventContinuation.yield(.channelRejected(topic: msg.topic, reason: reason))
            }
        }
    }

    // MARK: - postgres_changes dispatch

    private func handlePostgresChanges(_ msg: RealtimePhoenixMessage) {
        // Supabase Realtime payload shape for postgres_changes (v1.0.0+):
        //   { "data": {
        //        "type": "INSERT" | "UPDATE" | "DELETE",
        //        "schema": "public",
        //        "table": "team_events" | "direct_messages",
        //        "record": { ...columns... },
        //        "old_record": { ... }   // present on UPDATE/DELETE
        //     }, "ids": [...] }
        //
        // Some versions place fields at the top level of payload (no "data" wrapper);
        // we accept both shapes to be forward-compat.
        let data = (msg.payload["data"] as? [String: Any]) ?? msg.payload
        let type = (data["type"] as? String) ?? ""
        let table = (data["table"] as? String) ?? ""
        let record = (data["record"] as? [String: Any]) ?? [:]
        guard !record.isEmpty else { return }
        dispatchRecord(type: type, table: table, record: record)
    }

    private func dispatchRecord(type: String, table: String, record: [String: Any]) {
        switch (table, type) {
        case ("team_events", "INSERT"):
            if let row = decodeTeamEventRow(record) {
                eventContinuation.yield(.teamEventInserted(record: row))
            }
        case ("direct_messages", "INSERT"):
            if let row = decodeDirectMessageRow(record) {
                eventContinuation.yield(.directMessageInserted(record: row))
            }
        case ("direct_messages", "UPDATE"):
            if let row = decodeDirectMessageRow(record) {
                eventContinuation.yield(.directMessageUpdated(record: row))
            }
        default:
            // Unknown (table, type) combo — silently skip. Forward-compatible
            // with future tables we subscribe to but haven't routed yet.
            break
        }
    }

    // MARK: - Heartbeat (D.5)

    /// Start the heartbeat loop. Called on every successful connect / reconnect.
    /// Idempotent — cancels any in-flight loop first.
    private func startHeartbeat() {
        heartbeatTask?.cancel()
        missedHeartbeats = 0
        let interval = heartbeatIntervalSec
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                let sleepNanos = UInt64(max(interval, 0) * 1_000_000_000)
                if sleepNanos > 0 {
                    try? await Task.sleep(nanoseconds: sleepNanos)
                }
                if Task.isCancelled { return }
                await self?.tickHeartbeat()
            }
        }
    }

    /// Cancel + clear the heartbeat task. Safe to call multiple times.
    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    /// One heartbeat iteration. If we've already accumulated `missingHeartbeatLimit`
    /// unanswered heartbeats, treat the connection as dead and trigger reconnect;
    /// otherwise send a fresh heartbeat frame and increment the unanswered counter
    /// (decremented when the matching phx_reply arrives in `handlePhxReply`).
    private func tickHeartbeat() async {
        guard state.isActive else { return }
        if missedHeartbeats >= missingHeartbeatLimit {
            await handleConnectionLoss(reason: "heartbeat timeout (\(missedHeartbeats) missed)")
            return
        }
        guard let task = wsTask else {
            await handleConnectionLoss(reason: "heartbeat: ws task gone")
            return
        }
        do {
            let frame = try RealtimePhoenixFrame.heartbeat(ref: "hb-\(nextRef())")
            try await task.send(.string(frame))
            missedHeartbeats += 1
        } catch {
            await handleConnectionLoss(reason: "heartbeat send failed: \(error)")
        }
    }

    // MARK: - Reconnect (D.6)

    /// Compute the backoff delay (ms) for reconnect attempt #N.
    /// Schedule: 1s, 2s, 4s, 8s, 16s, then steady 16s.
    /// Pure function — exposed for direct unit testing of the schedule.
    public static func delayForReconnectAttempt(
        _ attempt: Int,
        baseMs: Int64 = 1_000,
        maxMs: Int64 = 16_000
    ) -> Int64 {
        let n = max(1, attempt)
        // Cap exponent at 4 → 2^4 = 16 multiplier on base.
        let exp = min(n - 1, 4)
        let scaled = baseMs &* Int64(1 << exp)
        return min(scaled, maxMs)
    }

    /// Common WS-level "connection is gone" handler. Stops heartbeat, tears down
    /// the WS task, yields a `.disconnected` event, and (if the driver is still
    /// in an active state) kicks off the reconnect loop. If the user has explicitly
    /// disconnected or suspended, no reconnect is attempted.
    private func handleConnectionLoss(reason: String) async {
        stopHeartbeat()
        wsTask?.cancel(with: .abnormalClosure, reason: nil)
        wsTask = nil
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        let topicWasJoined = currentChannelTopic != nil
        // Preserve currentChannelTopic / WorkspaceID so reconnect can re-join.
        // We clear them only on graceful disconnect / suspend / hard phx_close.
        eventContinuation.yield(.disconnected(reason: reason))
        guard state.isActive else { return }
        // Suppress unused-warning when not joined — reserved for future hooks.
        _ = topicWasJoined
        await startReconnectLoop()
    }

    /// Backoff loop. State transitions to `.reconnecting(attempt: N)` and stays
    /// there until either (a) reconnect succeeds (→ `.connected`), (b) the
    /// user explicitly cancels via `disconnect()` / `suspend()` (which calls
    /// `stopReconnectLoop`), or (c) `maxReconnectAttempts` is exhausted — in
    /// which case the driver transitions to terminal `.disconnected` and the
    /// caller (LeafRealtimeService) is expected to surface a banner / require
    /// explicit `resume()`. Each attempt sleeps the computed backoff before
    /// trying; the sleep delay is jittered by ±`reconnectJitterFraction` to
    /// prevent thundering-herd reconnect after a DO restart.
    private func startReconnectLoop() async {
        reconnectTask?.cancel()
        let cap = maxReconnectAttempts
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            var attempt = 1
            while !Task.isCancelled {
                if cap > 0 && attempt > cap {
                    // Hard-cap exhausted — give up and surface a terminal
                    // .disconnected so the user / service layer can react.
                    await self.terminateReconnectLoop(
                        reason: "reconnect cap exhausted after \(cap) attempts"
                    )
                    return
                }
                let delayMs = await self.reconnectDelayJittered(attempt: attempt)
                await self.setState(.reconnecting(attempt: attempt))
                let sleepNanos = UInt64(delayMs) &* 1_000_000
                try? await Task.sleep(nanoseconds: sleepNanos)
                if Task.isCancelled { return }
                do {
                    try await self.attemptReconnect()
                    return  // success — caller's setState(.connected) already ran inside attemptReconnect
                } catch {
                    // Backoff and try again. Cap the in-memory attempt counter
                    // so it can't overflow on a multi-day outage; the delay is
                    // already capped at reconnectMaxDelayMs.
                    attempt = min(attempt + 1, 100)
                }
            }
        }
    }

    /// Helper exposed inside the actor so the reconnect Task can call the
    /// instance-scoped `delayForReconnectAttempt` with the configured base/max.
    private func reconnectDelay(attempt: Int) -> Int64 {
        Self.delayForReconnectAttempt(attempt, baseMs: reconnectBaseDelayMs, maxMs: reconnectMaxDelayMs)
    }

    /// Production-side wrapper that applies jitter on top of the pure
    /// `delayForReconnectAttempt` schedule. Pure function stays
    /// deterministic for unit tests; jitter is opt-in via init param.
    private func reconnectDelayJittered(attempt: Int) -> Int64 {
        let base = reconnectDelay(attempt: attempt)
        guard reconnectJitterFraction > 0 else { return base }
        // Multiply by Double.random(in: (1 - f)...(1 + f)).
        let lo = max(0.0, 1.0 - reconnectJitterFraction)
        let hi = 1.0 + reconnectJitterFraction
        let scaled = Double(base) * Double.random(in: lo...hi)
        return Int64(scaled)
    }

    /// Tear down the reconnect loop after hitting the attempt cap.
    /// Yields a `.disconnected` event with the cap reason so the consumer
    /// can show "couldn't reconnect" instead of a perpetual spinner.
    /// `async` so the caller's await syntax composes with the rest of the
    /// loop's actor-hopped state transitions even though `setState` itself
    /// is sync — keeps the API uniform with `setState(.reconnecting(...))`.
    private func terminateReconnectLoop(reason: String) async {
        setState(.disconnected)
        eventContinuation.yield(.disconnected(reason: reason))
    }

    /// One reconnect attempt. Throws on failure to send phx_join (or if there's
    /// no URL/JWT captured). On success: state → `.connected`, heartbeat restarted,
    /// channel re-joined if there was a prior `currentChannelWorkspaceID`.
    ///
    /// P1 hot-fix — before each attempt, if a service-injected `jwtProvider` is
    /// wired, ask it for a fresh JWT. Replaces the cached `lastConnectJWT` so
    /// reconnect cycles never replay an expired token (the bug that caused
    /// silent phx_join rejection storms on multi-hour Macs).
    private func attemptReconnect() async throws {
        // Pre-reconnect JWT refresh (P1 hot-fix). Synchronous-feeling await
        // inside the actor is fine — the reconnect Task is already async and
        // each attempt sleeps backoff first.
        if let provider = jwtProvider, let fresh = await provider() {
            lastConnectJWT = fresh
        }
        guard let url = lastConnectURL, let jwt = lastConnectJWT else {
            throw RealtimeError.notConnected
        }
        let request = URLRequest(url: url)
        let task = taskFactory(request)
        wsTask = task
        task.resume()
        state = .connected
        missedHeartbeats = 0
        receiveLoopTask = Task { [weak self] in
            await self?.receiveLoop()
        }
        startHeartbeat()
        // Re-join the prior channel if we had one. JWT used for phx_join is
        // either the freshly-provided one (if jwtProvider was wired) or the
        // last-known `lastConnectJWT` as fallback.
        if let wid = currentChannelWorkspaceID {
            let ref = nextRef()
            let frame = try RealtimePhoenixFrame.phxJoin(
                workspaceID: wid,
                accessToken: jwt,
                ref: ref
            )
            try await task.send(.string(frame))
        }
    }

    /// Cancel + clear the reconnect loop. Safe to call multiple times.
    private func stopReconnectLoop() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    /// Internal helper so the reconnect Task can mutate state from outside the
    /// actor's synchronous context.
    private func setState(_ new: State) {
        state = new
    }

    // MARK: - Row decoders

    /// Decode a postgres_changes `record` object for table `team_events` into the
    /// existing wire-shape value type `SupabaseTeamEventRow`. Column names match
    /// the DB schema (snake_case); the record map mirrors what PostgREST GET returns.
    private func decodeTeamEventRow(_ record: [String: Any]) -> SupabaseTeamEventRow? {
        guard
            let eventID = record["event_id"] as? String,
            let workspaceID = record["workspace_id"] as? String,
            let senderPubkey = record["sender_pubkey"] as? String,
            let sourceKind = record["source_kind"] as? String,
            let kind = record["kind"] as? String,
            let encryptedHex = record["encrypted_payload"] as? String,
            let createdAtISO = record["created_at"] as? String
        else { return nil }
        let expiresAtISO = record["expires_at"] as? String
        let payloadBytes = Self.decodeByteaHex(encryptedHex)
        let createdAtMs = Self.iso8601ToMs(createdAtISO)
        return SupabaseTeamEventRow(
            eventID: eventID,
            workspaceID: workspaceID,
            senderPubkeyHex: senderPubkey,
            sourceKind: sourceKind,
            kind: kind,
            encryptedPayload: payloadBytes,
            createdAtISO: createdAtISO,
            createdAtMs: createdAtMs,
            expiresAtISO: expiresAtISO
        )
    }

    /// Decode a postgres_changes `record` object for table `direct_messages` into
    /// the existing wire-shape value type `SupabaseDirectMessageRow`.
    private func decodeDirectMessageRow(_ record: [String: Any]) -> SupabaseDirectMessageRow? {
        guard
            let messageID = record["message_id"] as? String,
            let workspaceID = record["workspace_id"] as? String,
            let senderPubkey = record["sender_pubkey"] as? String,
            let recipientPubkey = record["recipient_pubkey"] as? String,
            let kind = record["kind"] as? String,
            let encryptedHex = record["encrypted_payload"] as? String,
            let createdAtISO = record["created_at"] as? String
        else { return nil }
        let payloadBytes = Self.decodeByteaHex(encryptedHex)
        let crossPostJSON: String? = {
            if let s = record["cross_post"] as? String { return s }
            if let obj = record["cross_post"] as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: obj),
               let s = String(data: data, encoding: .utf8) {
                return s
            }
            return nil
        }()
        return SupabaseDirectMessageRow(
            messageID: messageID,
            workspaceID: workspaceID,
            senderPubkeyHex: senderPubkey,
            recipientPubkeyHex: recipientPubkey,
            kind: kind,
            encryptedPayload: payloadBytes,
            crossPostJSON: crossPostJSON,
            createdAtISO: createdAtISO,
            readAtISO: record["read_at"] as? String,
            doneAtISO: record["done_at"] as? String,
            doneByPubkeyHex: record["done_by_pubkey"] as? String,
            replyTo: record["reply_to"] as? String
        )
    }

    // MARK: - Ref counter

    private func nextRef() -> String {
        refCounter += 1
        return "\(refCounter)"
    }

    // MARK: - Static helpers (duplicated from SupabaseClient extensions to avoid actor hop)

    /// Decode PostgreSQL `\x<hex>` bytea representation to Data.
    /// Mirrors the helper in SupabaseClient+TeamEvents (kept local to avoid
    /// cross-file isolation; precedent for code duplication in Track 5).
    static func decodeByteaHex(_ s: String) -> Data {
        var hex = s
        if hex.hasPrefix("\\x") {
            hex = String(hex.dropFirst(2))
        }
        while hex.first == "\\" || hex.first == "x" {
            hex = String(hex.dropFirst())
        }
        var bytes = Data()
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            let pair = String(hex[idx..<next])
            if let byte = UInt8(pair, radix: 16) {
                bytes.append(byte)
            }
            idx = next
        }
        return bytes
    }

    static func iso8601ToMs(_ iso: String) -> Int64 {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: iso) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        let fb = ISO8601DateFormatter()
        fb.formatOptions = [.withInternetDateTime]
        if let date = fb.date(from: iso) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        return 0
    }
}
