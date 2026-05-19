//
//  PendingMarkDoneRetryService.swift
//  LeafCore
//
//  Track 5 / S8 T6 — background retry queue for APNs `dm.markDone` actions
//  that succeeded locally (optimistic UPDATE) but failed the Supabase PATCH.
//
//  Driven by `RootView.task` daily tick (same scheduling pattern as
//  `TeamEventMirrorRetentionPruner.pruneIfDueDaily`). Per-tick:
//    1. SELECT messages where `pending_mark_done = 1` (uses M026 partial index)
//    2. For each row, attempt server `markDone` via injected closure
//    3. On success: clear `pending_mark_done` flag → row drops out of retry set
//    4. On failure: leave `pending_mark_done = 1` for next tick (silent)
//
//  The service is intentionally narrow — it owns only the retry walk. The
//  optimistic local UPDATE + initial server PATCH attempt + flag-set on
//  failure live in `DirectMessageInboxReader.markDone(messageID:)` (the
//  callsite invoked by both the user's in-app Mark Done tap AND the APNs
//  `dm.markDone` action handler in `LeafAppDelegate`).
//
//  Test seam: the `PendingMarkDoneMirrorAccess` protocol lets tests inject a
//  pure in-memory double, decoupling unit-test runtime from SQLCipher boot.
//  Production conformance lives in this file as an extension on
//  `LeafCore.Database` (the shared writer handle).
//

import Foundation

/// Minimal mirror-surface dependency injection for `PendingMarkDoneRetryService`.
/// Production conformance via `Database` extension at the bottom of this file;
/// tests inject a pure actor double (see `PendingMarkDoneRetryServiceTests`).
public protocol PendingMarkDoneMirrorAccess: Sendable {
    /// SELECT message_ids where `messages_mirror.pending_mark_done = 1`.
    func fetchPendingMarkDone() async throws -> [String]

    /// UPDATE `messages_mirror.pending_mark_done = pending ? 1 : 0` for the
    /// given message_id.
    func setPendingMarkDone(messageID: String, pending: Bool) async throws
}

/// Background retry actor — single per-process instance, driven once per
/// daily tick from `RootView.task`. Holds no DB handle directly; all I/O
/// goes through the injected `PendingMarkDoneMirrorAccess` so the service
/// stays straightforward to unit-test without SQLCipher bootstrap.
public actor PendingMarkDoneRetryService {

    public typealias MarkDoneClient = @Sendable (_ messageID: String) async throws -> Void

    /// 24-hour cooldown between automatic ticks driven by
    /// `tickIfDueDaily(now:)`. Manual `tick()` calls bypass the cooldown
    /// (useful for tests + immediate-retry surfaces).
    public static let dailyCooldownSeconds: TimeInterval = 86_400

    private let mirror: PendingMarkDoneMirrorAccess
    private let markDone: MarkDoneClient
    private(set) var lastTickedAt: Date?

    public init(
        mirror: PendingMarkDoneMirrorAccess,
        markDone: @escaping MarkDoneClient
    ) {
        self.mirror = mirror
        self.markDone = markDone
    }

    /// Drain the retry queue: for each pending row, attempt server PATCH;
    /// clear flag on success, leave flag on failure (next tick will retry).
    ///
    /// Sequential — not parallelised. Pending retry sets are expected to be
    /// small (handful at most; failed-network spikes self-limit because the
    /// user has to tap [Mark Done] in the first place). A flat for-loop
    /// keeps server-side rate-limit pressure predictable.
    ///
    /// Errors from the mirror layer (e.g. DB write failure on flag clear)
    /// are propagated; errors from the server PATCH are absorbed silently
    /// per row (the entire point of the retry queue is to ride out PATCH
    /// failures).
    public func tick() async throws {
        let pendingIDs = try await mirror.fetchPendingMarkDone()
        for messageID in pendingIDs {
            do {
                try await markDone(messageID)
                try await mirror.setPendingMarkDone(messageID: messageID, pending: false)
            } catch {
                // Server PATCH failed (or transient network) — leave the
                // pending flag intact for the next tick. Silent on purpose:
                // background retry should not surface noisy logs.
                continue
            }
        }
    }

    /// Cooldown-gated wrapper around `tick()`. Returns immediately when the
    /// last tick fired within `dailyCooldownSeconds`. Used by `RootView.task`
    /// so the per-30s polling loop doesn't drown server PATCH attempts.
    /// Mirrors `TeamEventMirrorReader.pruneIfDueDaily(now:)` pattern.
    public func tickIfDueDaily(now: Date = Date()) async throws {
        if let last = lastTickedAt, now.timeIntervalSince(last) < Self.dailyCooldownSeconds {
            return
        }
        try await tick()
        lastTickedAt = now
    }
}

// MARK: - Production mirror conformance (Database-backed)

/// Production conformance on the shared `LeafCore.Database` writer handle.
/// Composition root (`LeafApp.init`) constructs the service with the same
/// `Database` instance the app uses for all other mirror writes; the
/// `Database` actor-mutex serialises concurrent access naturally.
extension Database: PendingMarkDoneMirrorAccess {

    public func fetchPendingMarkDone() async throws -> [String] {
        try self.readPendingMarkDoneMessageIDs()
    }

    public func setPendingMarkDone(messageID: String, pending: Bool) async throws {
        try self.writePendingMarkDoneFlag(messageID: messageID, pending: pending)
    }
}
