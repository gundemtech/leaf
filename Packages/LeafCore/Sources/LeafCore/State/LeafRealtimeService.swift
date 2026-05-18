//
//  LeafRealtimeService.swift
//  LeafCore
//
//  Track 5 / S7 — Phase D.7 + D.8 + D.9. @MainActor @Observable wrapper that
//  bridges the actor `RealtimeWebSocketDriver` to the existing readers:
//    • DirectMessageInboxReader.absorbRealtimePush(_:)
//    • TeamEventMirrorReader.absorbRealtimePush(_:)
//    • CrossPostLogReader.loadForMessages(_:) — fetched after DM insert
//
//  Architecture:
//    • The two DM/TeamEvent readers live in the app target — we accept them by
//      narrow protocol (`RealtimeDirectMessageAbsorbing` / `RealtimeTeamEventAbsorbing`)
//      so this service can live in LeafCore without an inverse dependency.
//    • CrossPostLogReader is already in LeafCore — we hold a strong ref.
//    • Decryption from encrypted-wire-format (Supabase*Row) to plaintext-mirror
//      format (*MirrorRow) is injected as a closure. Phase H composition wires
//      the real codecs via teamKey lookup.
//
//  C2/C3 trust gates (from S5 fix-bundle):
//    • C3: workspace_id in the encrypted wire row must equal currentWorkspaceID.
//      Cross-workspace rows are silently dropped (defence vs compromised relay
//      doing cross-workspace fan-out).
//    • C2: after decryption, the plaintext senderPubkeyHex must equal the
//      column-attested sender_pubkey from the wire row (server RLS attests the
//      column matches the JWT pubkey of the inserter; a compromised relay
//      cannot mutate the column without invalidating RLS).
//    • C3 redux: plaintext workspaceID must match wire row workspaceID.
//
//  Suspend/resume:
//    • suspend cancels the dispatch loop + suspends the driver (battery save).
//    • resume re-subscribes to the last workspace (from currentWorkspaceID or
//      activeWorkspaceStore.activeWorkspaceID).
//

import Foundation
import Observation

// MARK: - Reader injection protocols

/// Narrow protocol the app-target `DirectMessageInboxReader` conforms to.
/// Lets `LeafRealtimeService` live in LeafCore while readers live in the app
/// target without inverting the dependency.
@MainActor
public protocol RealtimeDirectMessageAbsorbing: AnyObject {
    func absorbRealtimePush(_ row: DirectMessageMirrorRow) async
}

/// Narrow protocol the app-target `TeamEventMirrorReader` conforms to.
@MainActor
public protocol RealtimeTeamEventAbsorbing: AnyObject {
    func absorbRealtimePush(_ row: TeamEventMirrorRow) async
}

// MARK: - LeafRealtimeService

@MainActor
@Observable
public final class LeafRealtimeService {

    public enum ConnectionState: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        case reconnecting(attempt: Int)
        case suspended
    }

    // MARK: - Published surface

    public private(set) var state: ConnectionState = .disconnected
    public private(set) var currentWorkspaceID: String?

    // MARK: - Dependencies

    private let driver: RealtimeWebSocketDriver
    private let supabase: SupabaseClient
    private let activeWorkspaceStore: ActiveWorkspaceStore
    private weak var directMessageInboxReader: (any RealtimeDirectMessageAbsorbing)?
    private weak var teamEventMirrorReader: (any RealtimeTeamEventAbsorbing)?
    private let crossPostLogReader: CrossPostLogReader
    private let realtimeURL: URL
    private let teamEventDecryptor: @Sendable (SupabaseTeamEventRow) async throws -> TeamEventMirrorRow
    private let directMessageDecryptor: @Sendable (SupabaseDirectMessageRow) async throws -> DirectMessageMirrorRow

    // MARK: - Private state

    private var dispatchTask: Task<Void, Never>?

    // MARK: - Init

    /// Designated initializer.
    ///
    /// - parameter driver: the low-level WS actor (D.1-D.6).
    /// - parameter supabase: the network primitive — used only for
    ///   `currentAccessToken()` (no bootstrap is triggered from here).
    /// - parameter activeWorkspaceStore: used by `resume()` to recover the
    ///   workspace to subscribe back to if `currentWorkspaceID` got cleared.
    /// - parameter directMessageInboxReader: weak — app target owns lifetime.
    /// - parameter teamEventMirrorReader: weak — app target owns lifetime.
    /// - parameter crossPostLogReader: strong — LeafCore owns lifetime.
    /// - parameter realtimeURL: Supabase Realtime endpoint.
    /// - parameter teamEventDecryptor: wire→plaintext mapper for team_events.
    ///   Phase H wires the real codec via teamKey lookup.
    /// - parameter directMessageDecryptor: wire→plaintext mapper for direct_messages.
    public init(
        driver: RealtimeWebSocketDriver,
        supabase: SupabaseClient,
        activeWorkspaceStore: ActiveWorkspaceStore,
        directMessageInboxReader: any RealtimeDirectMessageAbsorbing,
        teamEventMirrorReader: any RealtimeTeamEventAbsorbing,
        crossPostLogReader: CrossPostLogReader,
        realtimeURL: URL,
        teamEventDecryptor: @escaping @Sendable (SupabaseTeamEventRow) async throws -> TeamEventMirrorRow,
        directMessageDecryptor: @escaping @Sendable (SupabaseDirectMessageRow) async throws -> DirectMessageMirrorRow
    ) {
        self.driver = driver
        self.supabase = supabase
        self.activeWorkspaceStore = activeWorkspaceStore
        self.directMessageInboxReader = directMessageInboxReader
        self.teamEventMirrorReader = teamEventMirrorReader
        self.crossPostLogReader = crossPostLogReader
        self.realtimeURL = realtimeURL
        self.teamEventDecryptor = teamEventDecryptor
        self.directMessageDecryptor = directMessageDecryptor
    }

    // MARK: - Public API

    /// Subscribe the connection to a workspace channel.
    ///
    /// Idempotent: same wid → no-op. Different wid → phx_leave for the prior
    /// channel + phx_join for the new one (channel switch on the persistent
    /// WS connection — no WS re-connect).
    ///
    /// On first call: opens the WS, joins the channel, transitions state to
    /// `.connecting` then `.connected`. If no access token is available (auth
    /// not bootstrapped yet), state stays `.disconnected`.
    public func subscribe(workspaceID: String) async {
        // D.7 idempotency: same workspace → no-op.
        guard workspaceID != currentWorkspaceID else { return }

        // If a prior subscription exists, send phx_leave first. The driver's
        // leaveCurrentChannel is a no-op if no ack was received yet (the
        // currentChannelTopic only sets on phx_reply ok), which is safe.
        if currentWorkspaceID != nil {
            await driver.leaveCurrentChannel()
        }

        currentWorkspaceID = workspaceID
        state = .connecting

        // Pull a fresh JWT from the SupabaseClient session. Passive read — no
        // bootstrap kick. If no session yet, fall back to .disconnected and
        // surface the caller to retry on the next tick.
        guard let jwt = await supabase.currentAccessToken() else {
            // S7 Stage 6 fix A-I1 — clear currentWorkspaceID so a caller retry
            // with the same wid isn't no-op'd by the idempotency guard above.
            currentWorkspaceID = nil
            state = .disconnected
            return
        }

        do {
            // Connect WS if not already connected. The driver is idempotent in
            // .connected/.connecting, but we still want to handle the suspended
            // and disconnected cases by re-establishing the socket.
            let driverState = await driver.state
            switch driverState {
            case .disconnected:
                try await driver.connect(url: realtimeURL, jwt: jwt)
            case .suspended:
                try await driver.resume()
            case .connecting, .connected, .reconnecting:
                // Already (re)connecting — driver will deliver join replies.
                break
            }
            // Join the new channel. Phoenix multiplexes channels on the single
            // WS, so this is cheap on subsequent calls.
            try await driver.joinWorkspaceChannel(workspaceID: workspaceID, accessToken: jwt)
            state = .connected
            // S7 Stage 6 fix A-I5 — start the dispatch loop at most ONCE per
            // service lifetime (driver instance), not per-subscribe. The prior
            // pattern cancel+recreate the for-await on every workspace switch,
            // racing with AsyncStream consumption in the cancellation window
            // (events emitted between cancel-A and start-B could be lost).
            // The C3 trust gate inside handleTeamEventInsert /
            // handleDirectMessageInsert already filters cross-workspace events,
            // so a single long-lived loop is correct.
            ensureDispatchLoop()
        } catch {
            // Connect or join failed (e.g., URL bogus, transport error). The
            // driver's reconnect loop (D.6) takes over if the WS was up and
            // dropped — we just reflect state and bail out.
            // S7 Stage 6 fix A-I1 — clear currentWorkspaceID on the failure
            // path for the same reason as the JWT-nil branch above.
            currentWorkspaceID = nil
            state = .disconnected
        }
    }

    /// Send phx_leave for the current channel; keeps the WS connection open.
    /// State transitions to `.disconnected` while the underlying WS stays up.
    /// Idempotent: no-op if nothing was subscribed.
    ///
    /// S7 Stage 6 fix A-I5 — does NOT cancel the dispatch loop. The loop is
    /// pinned to the driver lifetime; while unsubscribed, C3 gate inside the
    /// handlers drops any in-flight cross-workspace event silently.
    public func unsubscribe() async {
        await driver.leaveCurrentChannel()
        currentWorkspaceID = nil
        state = .disconnected
    }

    /// Close the WS gracefully; cancel reconnect timers; transition to
    /// `.suspended`. Used when scenePhase ≠ .active to save battery.
    /// Idempotent.
    ///
    /// S7 Stage 6 fix A-I5 — also tears down the dispatch loop so the suspended
    /// service holds no live AsyncStream consumer. resume() rebuilds the loop
    /// via subscribe() → ensureDispatchLoop().
    public func suspend() async {
        dispatchTask?.cancel()
        dispatchTask = nil
        await driver.suspend()
        state = .suspended
    }

    /// Re-open the WS using the last-known workspace.
    /// Used when scenePhase returns to .active. Idempotent w.r.t. non-suspended
    /// states (no-op if state ≠ .suspended).
    public func resume() async {
        guard state == .suspended else { return }
        // Recover the workspace to re-subscribe to. Prefer the live
        // currentWorkspaceID; fall back to the persisted active workspace.
        guard let wid = currentWorkspaceID ?? activeWorkspaceStore.activeWorkspaceID else {
            state = .disconnected
            return
        }
        // Reset bookkeeping so subscribe() doesn't no-op via idempotency.
        state = .disconnected
        currentWorkspaceID = nil
        await subscribe(workspaceID: wid)
    }

    // MARK: - Dispatch loop (D.8)

    /// S7 Stage 6 fix A-I5 — single-instance loop pinned to the driver/service
    /// lifetime. First subscribe() on a non-suspended service starts the loop;
    /// every subsequent subscribe() finds it already running and re-uses it.
    /// suspend() tears it down, paired with driver.suspend(); resume() rebuilds
    /// via the next subscribe() call. unsubscribe() does NOT touch the loop —
    /// C3 inside the handlers drops cross-workspace events silently while
    /// disconnected.
    private func ensureDispatchLoop() {
        guard dispatchTask == nil else { return }
        let stream = driver.events
        dispatchTask = Task { [weak self] in
            for await event in stream {
                if Task.isCancelled { return }
                guard let self else { return }
                await self.dispatch(event)
            }
        }
    }

    private func dispatch(_ event: RealtimeEvent) async {
        switch event {
        case .channelJoined(let topic):
            // The phx_join ack confirms the channel is live. We already
            // optimistically set .connected in subscribe(); the ack arriving
            // is a confirmation, not a re-transition.
            //
            // S7 Stage 6 fix M2 — verify the ack's topic matches the current
            // workspace. On rapid subscribe(A) → subscribe(B), a late ack from
            // the prior channel A would otherwise re-affirm .connected even
            // if B's join hasn't completed yet (state could already be
            // .connecting for B, then mis-flipped to .connected by A's stale
            // ack). The Phoenix topic format is `realtime:leaf-workspace-<wid>`
            // (RealtimePhoenixMessage.topicForWorkspace) — compare suffix
            // against currentWorkspaceID before transitioning.
            if let wid = currentWorkspaceID,
               topic == "realtime:leaf-workspace-\(wid)" {
                state = .connected
            }
            // else: stale ack from a prior channel — ignore silently. The
            // current channel's own ack will arrive separately.

        case .channelRejected:
            // Server rejected the join (RLS denied, JWT expired, etc.). A
            // future improvement: refresh the JWT and retry (A-I3 carry-over
            // — wire JWT refresh through `attemptReconnect` so long-running
            // sessions recover from stale-token rejects). For now we treat
            // this as terminal — the caller resubscribes.
            //
            // S7 Stage 6 fix A-I2 — clear currentWorkspaceID so the caller's
            // natural retry (with the same wid) actually proceeds past the
            // idempotency guard in subscribe(). Without this, the user is
            // pinned to .disconnected forever after a single server reject.
            currentWorkspaceID = nil
            state = .disconnected

        case .teamEventInserted(let row):
            await handleTeamEventInsert(row)

        case .directMessageInserted(let row):
            await handleDirectMessageInsert(row)

        case .directMessageUpdated(let row):
            await handleDirectMessageUpdate(row)

        case .disconnected:
            // Transport-level disconnect — the driver's reconnect loop (D.6)
            // takes over and will eventually rejoin. We reflect the transition
            // in our state so UI can show a "reconnecting…" indicator.
            state = .reconnecting(attempt: 1)
        }
    }

    private func handleTeamEventInsert(_ row: SupabaseTeamEventRow) async {
        // C3 trust gate: workspace_id must match the workspace we subscribed to.
        // Defence vs compromised relay attempting cross-workspace fan-out.
        guard row.workspaceID == currentWorkspaceID else { return }
        let mirrorRow: TeamEventMirrorRow
        do {
            mirrorRow = try await teamEventDecryptor(row)
        } catch {
            // Decryption failed (key not found, ciphertext malformed, etc.).
            // Skip silently — don't poison the stream.
            return
        }
        // C2 plaintext-trust gate: the senderPubkeyHex carried inside the
        // decrypted plaintext must match the column-attested sender_pubkey
        // (RLS enforces that column = JWT pubkey of inserter).
        guard mirrorRow.senderPubkeyHex == row.senderPubkeyHex else { return }
        // C3 plaintext-trust gate: workspaceID inside plaintext must also match.
        guard mirrorRow.workspaceID == row.workspaceID else { return }
        await teamEventMirrorReader?.absorbRealtimePush(mirrorRow)
    }

    private func handleDirectMessageInsert(_ row: SupabaseDirectMessageRow) async {
        // C3 trust gate: workspace_id must match.
        guard row.workspaceID == currentWorkspaceID else { return }
        let mirrorRow: DirectMessageMirrorRow
        do {
            mirrorRow = try await directMessageDecryptor(row)
        } catch {
            return
        }
        // C2: plaintext sender must match column.
        guard mirrorRow.senderPubkeyHex == row.senderPubkeyHex else { return }
        // C3 plaintext: workspaceID must match.
        guard mirrorRow.workspaceID == row.workspaceID else { return }
        await directMessageInboxReader?.absorbRealtimePush(mirrorRow)
        // After the DM lands, fetch the cross-post log for it. The
        // CrossPostLogReader is cache-aware so this is a no-op if already
        // cached (typically true on first delivery — cross_post_log rows
        // arrive 1-2s after DM INSERT once the Edge Function completes).
        await crossPostLogReader.loadForMessages([mirrorRow.messageID])
    }

    private func handleDirectMessageUpdate(_ row: SupabaseDirectMessageRow) async {
        // UPDATE events deliver the full updated row (e.g., read_at set on
        // outbound DMs). Delegate to the same INSERT path — absorbRealtimePush
        // is idempotent (UPSERT on local mirror), and we re-fire the
        // cross-post log fetch which is cache-elided.
        await handleDirectMessageInsert(row)
    }
}
