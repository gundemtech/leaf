import Foundation

/// Phase 5.5.C — pure orchestrator over `Database` + `RelayClient` + `PendingInvitesStore`.
/// Used by `PendingInvitesReader` (Leaf target) для UI surface'а pending invites list.
///
/// Service surface mirrors §4.5 spec:
/// - `loadVisible` → sweep expired + read non-consumed (D8 + D1).
/// - `pollPending` → batch GET .pending rows; 200 stamp lastPolledAtMs, 404 → .consumed,
///   transport / 5xx counted в `PollOutcome.networkErrors`.
/// - `revoke` → best-effort relay DELETE + local truth (DB authoritative, mirror
///   `InviteOutboxReader.revokeAndDismiss`).
/// - `dismiss` → hard DELETE row (terminal-state cleanup, D2).
public struct PendingInvitesService: Sendable {
    private let database: Database
    private let relayClient: RelayClient
    private let now: @Sendable () -> Date

    public init(
        database: Database,
        relayClient: RelayClient,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = database
        self.relayClient = relayClient
        self.now = now
    }

    /// Sync expired-sweep + read non-consumed rows. Idempotent — safe to call from .onAppear.
    public func loadVisible() throws -> [PendingInvite] {
        let nowMs = Int64(now().timeIntervalSince1970 * 1000)
        _ = try database.sweepExpiredPendingInvites(nowMs: nowMs)
        return try database.readAllPendingInvites()
    }

    /// Loop over `.pending` rows: GET each from relay; 200 keeps + stamps lastPolledAtMs;
    /// 404 (`inviteNotFound`) flips → `.consumed`; transport / 5xx counted, row untouched.
    public func pollPending() async throws -> PollOutcome {
        let nowMs = Int64(now().timeIntervalSince1970 * 1000)
        _ = try database.sweepExpiredPendingInvites(nowMs: nowMs)
        let rows = try database.readAllPendingInvitesByStatus(.pending)

        var consumed = 0
        var stillPending = 0
        var networkErrors = 0

        for row in rows {
            do {
                _ = try await relayClient.getInvite(token: row.token)
                try database.updatePendingInviteLastPolledAt(token: row.token, atMs: nowMs)
                stillPending += 1
            } catch LeafError.inviteNotFound {
                try database.updatePendingInviteStatus(token: row.token, status: .consumed)
                consumed += 1
            } catch {
                networkErrors += 1
            }
        }

        return PollOutcome(consumed: consumed, stillPending: stillPending, networkErrors: networkErrors)
    }

    /// Best-effort relay DELETE + local status flip → `.revoked`. DB write authoritative —
    /// если relay throws, row остаётся `.revoked` локально. Mirror
    /// `InviteOutboxReader.revokeAndDismiss` precedent (5.2.D).
    public func revoke(token: String) async throws {
        do {
            try await relayClient.deleteInvite(token: token)
        } catch {
            // Best-effort. Token one-shot consume is bound to `memberPubkeyHex` crypto;
            // operational risk низкий per spec §8.
        }
        try database.updatePendingInviteStatus(token: token, status: .revoked)
    }

    /// Hard DELETE row from DB. Used by [Dismiss] action на terminal-state rows.
    /// Silent no-op if token уже не существует — see `PendingInvitesStore.delete` semantics.
    public func dismiss(token: String) throws {
        try database.deletePendingInvite(token: token)
    }
}

/// Result of `pollPending` — surfaced to UI via `PendingInvitesReader.formatPollOutcome`.
public struct PollOutcome: Sendable, Equatable {
    public let consumed: Int
    public let stillPending: Int
    public let networkErrors: Int

    public init(consumed: Int, stillPending: Int, networkErrors: Int) {
        self.consumed = consumed
        self.stillPending = stillPending
        self.networkErrors = networkErrors
    }
}
