//
//  RealtimeWebSocketDriver.swift
//  LeafCore
//
//  Track 5 / S7 — Phase D.2 + D.3 + D.4. Phoenix Channels protocol implementation
//  wrapping URLSessionWebSocketTask. Owns:
//    • WS lifecycle (connect / disconnect / reconnect — D.5+)
//    • Phoenix message ref counter (monotonic per connection)
//    • Channel join state (single workspace channel at a time)
//    • Dispatch from postgres_changes → typed RealtimeEvent AsyncStream
//
//  Downstream consumer (Phase D.5+, LeafRealtimeService) reads the `events`
//  stream, resolves teamKey by keyID, decrypts, and routes to:
//    • DirectMessageInboxService.absorbRealtimePush(_:)
//    • TeamEventMirrorService.absorbRealtimePush(_:)
//
//  Test seams:
//    • `URLSessionWebSocketTaskProtocol` — mockable WS task
//    • `taskFactory` closure — inject mock factory in tests
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

    // MARK: - Private state

    private let eventContinuation: AsyncStream<RealtimeEvent>.Continuation
    private let taskFactory: @Sendable (URLRequest) -> URLSessionWebSocketTaskProtocol

    private var refCounter: Int = 0
    private var wsTask: (any URLSessionWebSocketTaskProtocol)?
    private var receiveLoopTask: Task<Void, Never>?

    /// Topic of the currently-joined channel (single channel at a time in S7).
    private var currentChannelTopic: String?

    // MARK: - Init

    public init(
        taskFactory: @escaping @Sendable (URLRequest) -> URLSessionWebSocketTaskProtocol = { request in
            URLSession.shared.webSocketTask(with: request)
        }
    ) {
        var continuationCapture: AsyncStream<RealtimeEvent>.Continuation!
        self.events = AsyncStream { continuation in
            continuationCapture = continuation
        }
        self.eventContinuation = continuationCapture
        self.taskFactory = taskFactory
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

        state = .connecting

        let request = URLRequest(url: url)
        let task = taskFactory(request)
        wsTask = task
        task.resume()

        // Transition to `.connected` happens optimistically here — URLSessionWebSocketTask
        // does not expose an "open" callback. Real connectivity is confirmed when phx_join
        // ack arrives (D.3). On WS upgrade failure, the first `receive()` throws and the
        // loop transitions us to `.disconnected`.
        state = .connected

        // Start receive loop. Captured `task` reference is the same one we just
        // stored in `wsTask`; weak self avoids retention through the loop.
        receiveLoopTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    // MARK: - Disconnect

    /// Gracefully close the WS — no auto-reconnect attempt. Idempotent.
    public func disconnect() async {
        wsTask?.cancel(with: .normalClosure, reason: nil)
        wsTask = nil
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        currentChannelTopic = nil
        state = .disconnected
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
    }

    /// Test-only inspector for the currently-joined channel topic.
    /// Production callers don't need this; the driver-internal state is the
    /// authoritative source of truth.
    public func currentTopic() -> String? { currentChannelTopic }

    // MARK: - Receive loop + dispatch

    private func receiveLoop() async {
        while !Task.isCancelled, state.isActive, let task = wsTask {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                // WS closed / error — surface + transition. Receive loop ends here.
                eventContinuation.yield(.disconnected(reason: "receive: \(error)"))
                state = .disconnected
                wsTask = nil
                currentChannelTopic = nil
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
        case "phx_error":
            // Server-side channel error (e.g., RLS denied mid-stream). Treat as
            // a disconnect; reconnect loop (D.6) decides whether to retry.
            eventContinuation.yield(.disconnected(reason: "phx_error"))
            currentChannelTopic = nil
        default:
            // heartbeat_reply, presence_diff, etc. — D.5 / future phases.
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
            // First phx_reply on a workspace topic → it's the phx_join ack.
            // We don't track per-ref state in S7 (single channel at a time).
            if msg.topic.hasPrefix("realtime:leaf-workspace-") {
                currentChannelTopic = msg.topic
                eventContinuation.yield(.channelJoined(topic: msg.topic))
            }
            // Other status:"ok" replies (e.g., heartbeat) are silent.
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
