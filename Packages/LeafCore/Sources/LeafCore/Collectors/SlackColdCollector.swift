//
//  SlackColdCollector.swift
//  LeafCore
//
//  Phase Track-3 D3 Task 14 — Slack cold-tier (4am local daily) collector
//  actor body. Mirrors `GitHubColdCollector` / `LinearColdCollector` shape:
//  actor + performTick + atomic write through
//  `Database.writeEventsOffsetsAndSnapshots`.
//
//  Four endpoint groups, 6 event_kinds:
//   1. canvases (per top-10 channel)    → slack_canvas_created / _edited
//      (canvasID-keyed diff + lastEditedMs monotone bump). Title routed
//      under `body` for FTS dispatch (body_kind = "slack_canvas_title").
//   2. emoji.list                        → slack_custom_emoji_added (name
//      set diff; removal intentionally not surfaced — see Task 7 spec).
//   3. usergroups.list + per-group users → slack_usergroup_membership_changed
//      (per-group added/removed userID set delta).
//   4. conversations.info (per top-10 channel) → slack_channel_renamed /
//      slack_channel_archived (name change + isArchived false→true).
//
//  Per-channel fan-out (canvases + channels_info) reads the warm-tier
//  `slack_member_channels` full-set snapshot and locally caps to top-N by
//  `latestTs` — the persisted snapshot intentionally holds the full set so
//  warm-tier join/left diffing is correct (C3 review fix).
//
//  Bootstrap discipline: first tick with no prior snapshot per slot writes
//  the snapshot but emits zero diff events; Day-2+ ticks produce the normal
//  added/edited/renamed/archived stream.
//
//  Scope gating: collector consults `SlackScopesChecking` BEFORE emitting
//  events for each endpoint group. Channels-info uses the same scope set
//  the warm tier already required (no new scope) — channel rename/archive
//  events emit unconditionally on a successful diff.
//
//  Atomic write: events + offset + snapshots through a single
//  `Database.writeEventsOffsetsAndSnapshots` transaction. Provider failure
//  → cursor stays at prior tick (retry next tick).
//
//  Privacy (ADR-010 §6): canvas titles (user-named structured resources) are
//  body-bearing; emoji image URLs / message content / file content are
//  never captured. Usergroup membership delta is the set of Slack user IDs
//  only — no profile data, no names.
//

import Foundation
import os

public actor SlackColdCollector {
    private let database: Database
    private let provider: any SlackAPIProvider
    private let tokenRefresher: SlackTokenRefresher
    private let scopes: any SlackScopesChecking
    private let workspaceIDProvider: @Sendable () -> String?
    private let userIDProvider: @Sendable () -> String?
    private let clock: @Sendable () -> Date
    private let logger: Logger

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

    @discardableResult
    public func performTick(now: Date? = nil) async -> TickResult {
        let tickNow = now ?? clock()
        let nowMs = Int64(tickNow.timeIntervalSince1970 * 1000)

        // 1. Integration row.
        let record: IntegrationRecord?
        do {
            record = try database.readIntegration(provider: .slack)
        } catch {
            logger.error("cold readIntegration failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: true, eventsEmitted: 0)
        }
        guard record != nil else { return TickResult(skipped: true, eventsEmitted: 0) }

        // 2. Token refresh.
        let refreshed: IntegrationRecord
        do {
            refreshed = try await tokenRefresher.refreshIfNeeded(now: tickNow)
        } catch SlackTokenRefresherError.refreshDenied(let msg) {
            logger.warning("cold refresh denied: \(msg, privacy: .public)")
            return TickResult(skipped: true, eventsEmitted: 0)
        } catch {
            logger.error("cold refresh failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: true, eventsEmitted: 0)
        }

        // 3. Resolve teamID + userID. Prefer integration record's "<team>:<user>"
        // format (single source of truth in production); fall back to closures
        // supplied at construction time.
        let teamID: String
        let userID: String
        let parts = refreshed.workspaceID.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty {
            teamID = String(parts[0])
            userID = String(parts[1])
        } else if let w = workspaceIDProvider(), let u = userIDProvider() {
            teamID = w
            userID = u
        } else {
            logger.error("malformed workspaceID '\(refreshed.workspaceID, privacy: .public)' — expected '<team>:<user>'")
            return TickResult(skipped: true, eventsEmitted: 0)
        }
        let sourceID = "slack:cold:\(teamID)"
        let workspaceID = teamID

        // 4. Top channels for fan-out — read the FULL member set persisted by
        // the warm tier under `slack_member_channels`, then locally cap to top-10
        // by `latestTs` for the provider's per-channel sub-fans. Empty when warm
        // hasn't run yet (cold gracefully no-ops the per-channel groups on its
        // first tick). C3 review fix: warm now persists the full set rather
        // than the cap (cap is applied at fan-out time, not at persist time).
        let fullMemberSet: SlackMemberChannelsTopList =
            readSnapshotValue(kind: Schema.ProviderSnapshotKinds.slackMemberChannels)
            ?? .empty
        let topChannels = SlackWarmCollector.rankTop10ByLatestTs(from: fullMemberSet.channels)

        // 5. Read prior cold snapshots + row-presence flags (bootstrap gate).
        let priorCanvases: SlackCanvasesSnapshot =
            readSnapshotValue(kind: Schema.ProviderSnapshotKinds.slackCanvasesPerChannel) ?? .empty
        let priorCanvasesRowPresent = snapshotRowPresent(kind: Schema.ProviderSnapshotKinds.slackCanvasesPerChannel)
        let priorEmoji: SlackEmojiSnapshot =
            readSnapshotValue(kind: Schema.ProviderSnapshotKinds.slackEmojiList) ?? .empty
        let priorEmojiRowPresent = snapshotRowPresent(kind: Schema.ProviderSnapshotKinds.slackEmojiList)
        let priorUsergroups: SlackUsergroupsSnapshot =
            readSnapshotValue(kind: Schema.ProviderSnapshotKinds.slackUsergroups) ?? .empty
        let priorUsergroupsRowPresent = snapshotRowPresent(kind: Schema.ProviderSnapshotKinds.slackUsergroups)
        let priorChannelsInfo: SlackChannelsInfoSnapshot =
            readSnapshotValue(kind: Schema.ProviderSnapshotKinds.slackChannelsInfo) ?? .empty
        let priorChannelsInfoRowPresent = snapshotRowPresent(kind: Schema.ProviderSnapshotKinds.slackChannelsInfo)

        // 6. Fetch cold state from provider. Per-endpoint failure tolerance
        // lives in the provider impl; a top-level throw aborts the tick entirely
        // and leaves the cursor unchanged (next tick retries).
        let batch: SlackColdBatch
        do {
            batch = try await provider.fetchColdState(
                accessToken: refreshed.accessToken,
                userID: userID,
                scopes: scopes,
                topChannels: topChannels,
                now: nowMs
            )
        } catch {
            logger.error("fetchColdState failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: false, eventsEmitted: 0)
        }

        // 7. Build events per endpoint group — scope-gated, bootstrap-gated.
        var events: [RawEvent] = []

        // 7a. Canvases.
        if await scopes.has("canvases:read"), priorCanvasesRowPresent {
            let (created, edited) = Self.canvasesPerChannelDiff(prior: priorCanvases, current: batch.canvases)
            for c in created {
                events.append(Self.makeCanvasCreatedEvent(
                    canvas: c, workspaceID: workspaceID, userID: userID, observedAtMs: nowMs
                ))
            }
            for c in edited {
                events.append(Self.makeCanvasEditedEvent(
                    canvas: c, workspaceID: workspaceID, userID: userID, observedAtMs: nowMs
                ))
            }
        }

        // 7b. Custom emoji (added only).
        if await scopes.has("emoji:read"), priorEmojiRowPresent {
            let d = Self.emojiSetDiff(prior: priorEmoji, current: batch.emoji)
            for name in d.added.sorted() {
                events.append(Self.makeCustomEmojiAddedEvent(
                    emojiName: name, workspaceID: workspaceID, observedAtMs: nowMs
                ))
            }
        }

        // 7c. Usergroups membership.
        if await scopes.has("usergroups:read"), priorUsergroupsRowPresent {
            let deltas = Self.usergroupsDiff(prior: priorUsergroups, current: batch.usergroups)
            for delta in deltas {
                events.append(Self.makeUsergroupMembershipChangedEvent(
                    groupID: delta.groupID,
                    addedUserIDs: delta.addedUserIDs,
                    removedUserIDs: delta.removedUserIDs,
                    workspaceID: workspaceID, userID: userID, observedAtMs: nowMs
                ))
            }
        }

        // 7d. Channels info (rename + archive). No new scope — uses the same
        // `channels:read` the warm tier already required for `users.conversations`.
        if priorChannelsInfoRowPresent {
            let (renamed, archived) = Self.channelsInfoDiff(prior: priorChannelsInfo, current: batch.channelsInfo)
            for r in renamed {
                events.append(Self.makeChannelRenamedEvent(
                    channelID: r.channelID, oldName: r.oldName, newName: r.newName,
                    workspaceID: workspaceID, observedAtMs: nowMs
                ))
            }
            for c in archived {
                events.append(Self.makeChannelArchivedEvent(
                    channel: c, workspaceID: workspaceID, observedAtMs: nowMs
                ))
            }
        }

        // 8. Offset row — tick wall clock; used by SlackColdScheduler catch-up gate.
        let offset = CollectorOffset(
            collectorID: CollectorID.slackColdPolling,
            sourceID: sourceID,
            byteOffset: 0, inode: nil, size: 0,
            lastModifiedMs: nowMs, updatedMs: nowMs
        )

        // 9. Snapshots — always written (bootstrap discipline gates events, not
        // persistence).
        let snapshots: [ProviderSnapshot] = [
            makeSnapshot(kind: Schema.ProviderSnapshotKinds.slackCanvasesPerChannel,
                         encoding: batch.canvases, nowMs: nowMs),
            makeSnapshot(kind: Schema.ProviderSnapshotKinds.slackEmojiList,
                         encoding: batch.emoji, nowMs: nowMs),
            makeSnapshot(kind: Schema.ProviderSnapshotKinds.slackUsergroups,
                         encoding: batch.usergroups, nowMs: nowMs),
            makeSnapshot(kind: Schema.ProviderSnapshotKinds.slackChannelsInfo,
                         encoding: batch.channelsInfo, nowMs: nowMs)
        ]

        // 10. Atomic write.
        do {
            try database.writeEventsOffsetsAndSnapshots(
                events: events, offsets: [offset], snapshots: snapshots
            )
        } catch {
            logger.error("cold persist failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: false, eventsEmitted: 0)
        }
        if !events.isEmpty {
            logger.info("slack cold tick wrote \(events.count, privacy: .public) events")
        }
        return TickResult(skipped: false, eventsEmitted: events.count)
    }

    // MARK: - Snapshot helpers

    private func snapshotRowPresent(kind: String) -> Bool {
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

    private func readSnapshotValue<T: Decodable>(kind: String) -> T? {
        let outer: ProviderSnapshot?? = try? database.readSQL { raw in
            try ProviderSnapshotsStore.read(
                provider: "slack", snapshotKind: kind, in: raw
            )
        }
        guard let s = outer.flatMap({ $0 }) else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(s.snapshotJSON.utf8))
    }

    private func makeSnapshot<T: Encodable>(kind: String, encoding value: T, nowMs: Int64) -> ProviderSnapshot {
        let json: String
        if let data = try? JSONEncoder().encode(value),
           let s = String(data: data, encoding: .utf8) {
            json = s
        } else {
            json = "{}"
        }
        return ProviderSnapshot(
            provider: "slack", snapshotKind: kind,
            snapshotJSON: json, capturedAtMs: nowMs
        )
    }

    // MARK: - Event builders

    static func makeCanvasCreatedEvent(
        canvas: SlackCanvas, workspaceID: String, userID: String, observedAtMs: Int64
    ) -> RawEvent {
        var payload: [String: String] = [
            "source": "slack",
            "event_kind": SlackEventKindKey.slackCanvasCreated.rawValue,
            Schema.EventPayloadKeys.canvasId: canvas.canvasID,
            Schema.EventPayloadKeys.bookmarkTitle: canvas.title,
            // Mirror title under canonical `body` so EventsFullTextStore can
            // route it to body_kind `slack_canvas_title` per ADR-010 §6 (canvas
            // titles are user-named structured resources).
            Schema.EventPayloadKeys.body: canvas.title,
            Schema.EventPayloadKeys.lastEditedMs: String(canvas.lastEditedMs),
            Schema.EventPayloadKeys.workspaceId: workspaceID,
            Schema.EventPayloadKeys.userId: userID,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs)
        ]
        if let cid = canvas.channelID {
            payload[Schema.EventPayloadKeys.channelId] = cid
        }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(canvas.lastEditedMs) / 1000.0),
            signalType: .action, bundleID: nil, payload: payload
        )
    }

    static func makeCanvasEditedEvent(
        canvas: SlackCanvas, workspaceID: String, userID: String, observedAtMs: Int64
    ) -> RawEvent {
        var payload: [String: String] = [
            "source": "slack",
            "event_kind": SlackEventKindKey.slackCanvasEdited.rawValue,
            Schema.EventPayloadKeys.canvasId: canvas.canvasID,
            Schema.EventPayloadKeys.bookmarkTitle: canvas.title,
            Schema.EventPayloadKeys.body: canvas.title,
            Schema.EventPayloadKeys.lastEditedMs: String(canvas.lastEditedMs),
            Schema.EventPayloadKeys.workspaceId: workspaceID,
            Schema.EventPayloadKeys.userId: userID,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs)
        ]
        if let cid = canvas.channelID {
            payload[Schema.EventPayloadKeys.channelId] = cid
        }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(canvas.lastEditedMs) / 1000.0),
            signalType: .action, bundleID: nil, payload: payload
        )
    }

    static func makeCustomEmojiAddedEvent(
        emojiName: String, workspaceID: String, observedAtMs: Int64
    ) -> RawEvent {
        let payload: [String: String] = [
            "source": "slack",
            "event_kind": SlackEventKindKey.slackCustomEmojiAdded.rawValue,
            Schema.EventPayloadKeys.emojiName: emojiName,
            Schema.EventPayloadKeys.workspaceId: workspaceID,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs)
        ]
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .action, bundleID: nil, payload: payload
        )
    }

    static func makeUsergroupMembershipChangedEvent(
        groupID: String,
        addedUserIDs: Set<String>,
        removedUserIDs: Set<String>,
        workspaceID: String, userID: String, observedAtMs: Int64
    ) -> RawEvent {
        let payload: [String: String] = [
            "source": "slack",
            "event_kind": SlackEventKindKey.slackUsergroupMembershipChanged.rawValue,
            Schema.EventPayloadKeys.groupId: groupID,
            Schema.EventPayloadKeys.addedUserIdsJson: encodeIDArray(addedUserIDs),
            Schema.EventPayloadKeys.removedUserIdsJson: encodeIDArray(removedUserIDs),
            Schema.EventPayloadKeys.workspaceId: workspaceID,
            Schema.EventPayloadKeys.userId: userID,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs)
        ]
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .context, bundleID: nil, payload: payload
        )
    }

    static func makeChannelRenamedEvent(
        channelID: String, oldName: String, newName: String,
        workspaceID: String, observedAtMs: Int64
    ) -> RawEvent {
        let payload: [String: String] = [
            "source": "slack",
            "event_kind": SlackEventKindKey.slackChannelRenamed.rawValue,
            Schema.EventPayloadKeys.channelId: channelID,
            Schema.EventPayloadKeys.oldName: oldName,
            Schema.EventPayloadKeys.newName: newName,
            Schema.EventPayloadKeys.workspaceId: workspaceID,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs)
        ]
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .context, bundleID: nil, payload: payload
        )
    }

    static func makeChannelArchivedEvent(
        channel: SlackChannelInfo, workspaceID: String, observedAtMs: Int64
    ) -> RawEvent {
        let payload: [String: String] = [
            "source": "slack",
            "event_kind": SlackEventKindKey.slackChannelArchived.rawValue,
            Schema.EventPayloadKeys.channelId: channel.channelID,
            Schema.EventPayloadKeys.channelName: channel.name,
            Schema.EventPayloadKeys.workspaceId: workspaceID,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs)
        ]
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .context, bundleID: nil, payload: payload
        )
    }

    /// Encodes a Set<String> as a JSON string array `["u1","u2"]` with sorted
    /// elements for deterministic payload bytes (tests + downstream FTS rely on
    /// a stable ordering).
    private static func encodeIDArray(_ ids: Set<String>) -> String {
        let sorted = ids.sorted()
        guard let data = try? JSONEncoder().encode(sorted),
              let s = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return s
    }
}
