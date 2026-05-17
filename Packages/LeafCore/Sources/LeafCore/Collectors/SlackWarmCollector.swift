//
//  SlackWarmCollector.swift
//  LeafCore
//
//  Phase Track-3 D3 Task 12 — Slack warm-tier (15m) collector actor body.
//  Mirrors GitHubWarmCollector / LinearWarmCollector shape — actor + start/stop
//  loop + performTick + atomic write through `Database.writeEventsOffsetsAndSnapshots`.
//
//  Seven endpoint groups, 13 event_kinds:
//   1. user.conversations → slack_channel_joined / _left (top-10 latestTs rank)
//   2. reactions.list (self-authored) → slack_reaction_added (positive deltas only,
//      bucketed emoji per ADR-010 §6 — no raw emoji name)
//   3. pins.list (per top-10 channel) → slack_pin_added / _removed (id-set diff)
//   4. bookmarks.list (per top-10 channel) → slack_bookmark_added / _removed (id diff,
//      title routes through `body` for FTS pickup — body_kind `slack_bookmark_title`)
//   5. reminders.list → slack_reminder_created / _completed (id diff + completedTs
//      transition)
//   6. chat.scheduledMessages.list → slack_message_scheduled / _sent_scheduled
//      (id diff + sent transition; disappeared rows treated as sent)
//   7. stars.list → slack_item_saved / _unsaved (itemRef set-diff)
//
//  Bootstrap discipline: first tick with no prior snapshot per slot writes
//  the snapshot but emits zero diff events. Subsequent ticks produce the
//  normal added/removed/transition stream.
//
//  Scope gating: collector consults `SlackScopesChecking` BEFORE emitting
//  events for each endpoint group. Provider implementation honours scopes
//  too (returns empty arrays for missing scopes) but collector double-guards
//  emission so that out-of-spec provider stubs cannot leak events for
//  missing-scope endpoints.
//
//  Atomic write: events + offset + snapshots through a single
//  `Database.writeEventsOffsetsAndSnapshots` transaction. Provider failure
//  → no write → cursor stays at prior tick (retry next tick).
//
//  Privacy (ADR-010 §6): pinned-message bodies / message text / reminder
//  text / scheduled-message text / file content — never captured. Bookmark
//  titles are user-named structured resources (not message bodies) and are
//  allowed by ADR-010 §6.
//
//  Phase 2.3.C.3 split — `performTick` lives in `SlackWarmCollector+Tick.swift`,
//  static event builders in `SlackWarmCollector+EventBuilders.swift`,
//  diff helpers in `SlackWarmCollector+Diffs.swift`.
//

import Foundation
import os

public actor SlackWarmCollector {
    /// Cap on member-channels persisted to snapshot + fanned out per-channel.
    public static let topN = 10

    let database: Database
    let provider: any SlackAPIProvider
    let tokenRefresher: SlackTokenRefresher
    let scopes: any SlackScopesChecking
    let workspaceIDProvider: @Sendable () -> String?
    let userIDProvider: @Sendable () -> String?
    let clock: @Sendable () -> Date
    let logger: Logger

    public init(
        database: Database,
        provider: any SlackAPIProvider,
        tokenRefresher: SlackTokenRefresher,
        scopes: any SlackScopesChecking,
        workspaceIDProvider: @escaping @Sendable () -> String?,
        userIDProvider: @escaping @Sendable () -> String?,
        clock: @escaping @Sendable () -> Date = { Date() },
        logger: Logger
    ) {
        self.database = database
        self.provider = provider
        self.tokenRefresher = tokenRefresher
        self.scopes = scopes
        self.workspaceIDProvider = workspaceIDProvider
        self.userIDProvider = userIDProvider
        self.clock = clock
        self.logger = logger
    }

    public struct TickResult: Sendable, Equatable {
        public let skipped: Bool
        public let eventsEmitted: Int
        public init(skipped: Bool, eventsEmitted: Int) {
            self.skipped = skipped
            self.eventsEmitted = eventsEmitted
        }
    }

    // MARK: - Snapshot helpers

    func snapshotRowPresent(kind: String) -> Bool {
        do {
            return try database.readSQL { raw in
                try ProviderSnapshotsStore.read(
                    provider: "slack", snapshotKind: kind, in: raw
                ) != nil
            }
        } catch {
            return false
        }
    }

    func readSnapshotArray<T: Decodable>(kind: String) -> [T] {
        let outer: ProviderSnapshot?? = try? database.readSQL { raw in
            try ProviderSnapshotsStore.read(
                provider: "slack", snapshotKind: kind, in: raw
            )
        }
        guard let s = outer.flatMap({ $0 }) else { return [] }
        return (try? JSONDecoder().decode([T].self, from: Data(s.snapshotJSON.utf8))) ?? []
    }

    func readSnapshotValue<T: Decodable>(kind: String) -> T? {
        let outer: ProviderSnapshot?? = try? database.readSQL { raw in
            try ProviderSnapshotsStore.read(
                provider: "slack", snapshotKind: kind, in: raw
            )
        }
        guard let s = outer.flatMap({ $0 }) else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(s.snapshotJSON.utf8))
    }

    func makeSnapshot<T: Encodable>(kind: String, encoding value: T, nowMs: Int64) -> ProviderSnapshot {
        let json: String
        if let data = try? JSONEncoder().encode(value),
            let s = String(data: data, encoding: .utf8)
        {
            json = s
        } else {
            json = "{}"
        }
        return ProviderSnapshot(
            provider: "slack", snapshotKind: kind,
            snapshotJSON: json, capturedAtMs: nowMs
        )
    }
}
