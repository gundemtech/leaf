//
//  WorkspaceCascadeDeleter.swift
//  LeafCore
//
//  Track 5 / S8 / T8 — local cache wipe for left/deleted workspaces.
//
//  Two entry points share one cascade implementation:
//    • `execute(workspaceID:)` — manual hard-wipe from Settings UI.
//    • `pruneExpiredLeftWorkspaces()` — daily-tick batch for workspaces past
//      `left_at_ms + 30d` OR `deleted_at_ms + 30d`. Idempotent.
//
//  **Audit invariant (sec C2):** Preserves `team_keys` + `team_members` rows
//  so decryption history remains available for forensic / rejoin scenarios.
//  `WorkspaceService.softDelete` (Workspace.swift line ~168) documents the
//  same invariant for the soft-delete path; hard-wipe only removes cache +
//  the workspace row itself, not auth metadata.
//
//  Closes S7 C-I7 — `LeaveWorkspaceConfirmationModal` copy "auto-delete
//  after 30 days" now has a real implementation to back it up.
//

import Foundation
import GRDB
import OSLog

/// Actor wrapper around the cascade DELETE + keystore wipe + daily-tick prune.
///
/// `execute(workspaceID:)` performs the cascade inside a single write
/// transaction on cache tables, then deletes the workspace row, and finally
/// removes the per-workspace keystore sub-folder OUTSIDE the transaction
/// (filesystem operation cannot be rolled back; orphan file < orphan row
/// matches `WorkspaceService.createWorkspace` keystore-first ordering).
///
/// `pruneExpiredLeftWorkspaces()` scans `workspaces` for rows past the
/// 30-day retention threshold (whichever of `left_at_ms` / `deleted_at_ms`
/// is set + 30d) and invokes `execute` per match. Returns the wiped IDs so
/// the caller can refresh UI state.
public actor WorkspaceCascadeDeleter {
    /// Retention window in days for the daily-tick pruner. Decoupled from the
    /// `TeamEventMirrorRetentionPruner.defaultRetentionDays` (90d) — those are
    /// independent retention concerns: T8 wipes after a workspace is left or
    /// deleted; mirror retention prunes individual rows in still-active
    /// workspaces.
    public static let retentionDays: Int = 30

    /// S8 review B-Imp-3 — cooldown between automatic prune ticks driven by
    /// `tickIfDueDaily(now:)`. Mirrors `PendingMarkDoneRetryService` pattern.
    /// `RootView.task` fires every ~30s; this gate ensures the cascade SELECT
    /// only runs once per 24h. Manual `pruneExpiredLeftWorkspaces()` calls
    /// bypass the cooldown (useful for tests + admin force-prune surfaces).
    public static let dailyCooldownSeconds: TimeInterval = 86_400

    private let database: LeafCore.Database
    private let keystoreRoot: URL
    private let now: @Sendable () -> Date
    private let logger: Logger
    private(set) var lastPrunedAt: Date?

    public init(
        database: LeafCore.Database,
        keystoreRoot: URL = TeamKeystore.defaultRoot(),
        now: @escaping @Sendable () -> Date = { Date() },
        logger: Logger = Logger(subsystem: "tech.gundem.leaf.core", category: "workspace-cascade-deleter")
    ) {
        self.database = database
        self.keystoreRoot = keystoreRoot
        self.now = now
        self.logger = logger
    }

    /// Single-transaction cascade DELETE on cache tables + workspace row;
    /// keystore folder wiped outside transaction (filesystem op).
    ///
    /// Tables wiped (workspace-scoped rows):
    ///   - `messages_mirror`
    ///   - `team_events_mirror`
    ///   - `share_rules`
    ///   - `team_event_broadcast_offsets`
    ///   - `pending_invites`
    ///   - `workspaces` (the row itself)
    ///
    /// Tables PRESERVED per audit invariant:
    ///   - `team_keys`     (history decryption — see WorkspaceService.softDelete:168)
    ///   - `team_members`  (forensic / rejoin scenarios)
    ///
    /// Idempotent: cascade DELETEs match 0 rows on second call; keystore
    /// removal is `try?`-guarded inside `TeamKeystore.deleteWorkspace`.
    public func execute(workspaceID: String) throws {
        try database.writeSQL { rawDB in
            try rawDB.execute(
                sql: "DELETE FROM \(Schema.MessagesMirror.tableName) WHERE \(Schema.MessagesMirror.workspaceID) = ?",
                arguments: [workspaceID]
            )
            try rawDB.execute(
                sql: "DELETE FROM \(Schema.TeamEventsMirror.tableName) WHERE \(Schema.TeamEventsMirror.workspaceID) = ?",
                arguments: [workspaceID]
            )
            try rawDB.execute(
                sql: "DELETE FROM \(Schema.ShareRules.tableName) WHERE \(Schema.ShareRules.workspaceID) = ?",
                arguments: [workspaceID]
            )
            try rawDB.execute(
                sql: "DELETE FROM \(Schema.TeamEventBroadcastOffsets.tableName) WHERE \(Schema.TeamEventBroadcastOffsets.workspaceID) = ?",
                arguments: [workspaceID]
            )
            try rawDB.execute(
                sql: "DELETE FROM \(Schema.PendingInvites.tableName) WHERE \(Schema.PendingInvites.workspaceID) = ?",
                arguments: [workspaceID]
            )
            // Drop the workspace row itself; team_keys + team_members
            // intentionally NOT touched per audit invariant (sec C2).
            try rawDB.execute(
                sql: "DELETE FROM \(Schema.Workspaces.tableName) WHERE \(Schema.Workspaces.id) = ?",
                arguments: [workspaceID]
            )
        }

        // Keystore wipe outside transaction (filesystem op cannot roll back).
        // Best-effort — internal error is logged but not propagated since the
        // DB row is already gone; a stray keystore folder is harmless leftover
        // disk space, not a correctness issue. Mirrors softDelete's `try?`
        // discipline.
        do {
            try TeamKeystore.deleteWorkspace(workspaceID: workspaceID, at: keystoreRoot)
        } catch {
            logger.warning("keystore wipe failed for workspace=\(workspaceID, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Daily-tick pruner. Scans `workspaces` for rows where:
    ///   - `left_at_ms` is non-NULL and < `now - 30d`, OR
    ///   - `deleted_at_ms` is non-NULL and < `now - 30d`.
    /// Invokes `execute(workspaceID:)` per match. Returns wiped workspace IDs.
    ///
    /// Idempotent: a row wiped by an earlier tick no longer exists, so
    /// subsequent ticks return an empty list. If a workspace is rejoined
    /// before the 30d window expires (clearWorkspaceLeftAt), it's no longer
    /// matched by the SELECT.
    @discardableResult
    public func pruneExpiredLeftWorkspaces() throws -> [String] {
        let nowMs = Int64(now().timeIntervalSince1970 * 1000)
        let thresholdMs = nowMs - Int64(Self.retentionDays) * 86_400_000
        // Filter rows that crossed the 30-day boundary on EITHER axis. A
        // workspace that was both left and then deleted (or deleted then left)
        // still wipes on whichever timestamp matches first; we don't need a
        // composite predicate since a single match triggers the wipe.
        let expiredIDs: [String] = try database.readSQL { rawDB in
            try String.fetchAll(rawDB, sql: """
                SELECT \(Schema.Workspaces.id) FROM \(Schema.Workspaces.tableName)
                WHERE (\(Schema.Workspaces.leftAtMs) IS NOT NULL AND \(Schema.Workspaces.leftAtMs) < ?)
                   OR (\(Schema.Workspaces.deletedAtMs) IS NOT NULL AND \(Schema.Workspaces.deletedAtMs) < ?)
                """,
                arguments: [thresholdMs, thresholdMs])
        }
        for wid in expiredIDs {
            try execute(workspaceID: wid)
        }
        if !expiredIDs.isEmpty {
            logger.info("auto-pruned \(expiredIDs.count, privacy: .public) expired workspace(s)")
        }
        return expiredIDs
    }

    /// S8 review B-Imp-3 — cooldown-gated wrapper around
    /// `pruneExpiredLeftWorkspaces()`. Returns `[]` immediately if the last
    /// prune fired within `dailyCooldownSeconds`. Used by `RootView.task` so
    /// the per-30s polling loop doesn't repeatedly SELECT the workspaces
    /// table when no workspace is anywhere near the 30d boundary.
    /// Mirrors `PendingMarkDoneRetryService.tickIfDueDaily(now:)` pattern.
    @discardableResult
    public func tickIfDueDaily(currentTime: Date? = nil) throws -> [String] {
        let stamp = currentTime ?? now()
        if let last = lastPrunedAt, stamp.timeIntervalSince(last) < Self.dailyCooldownSeconds {
            return []
        }
        let wiped = try pruneExpiredLeftWorkspaces()
        lastPrunedAt = stamp
        return wiped
    }
}
