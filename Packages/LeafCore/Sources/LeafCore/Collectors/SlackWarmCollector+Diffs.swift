//
//  SlackWarmCollector+Diffs.swift
//  LeafCore
//
//  Phase Track-3 D3 Task 7 — pure static diff helpers for warm-tier (15m)
//  Slack endpoint groups. No IO, no side effects, no logging. Each helper
//  consumes prior + current snapshots and returns added/removed/transition
//  event lists; Task 12's `SlackWarmCollector.performTick` composes these
//  into RawEvent emissions.
//
//  Mirrors the precedent set by `GitHubWarmCollector.projectsV2Diff(...)` in
//  D2 Task 7 — pure-function siblings to the eventual `public actor` collector.
//  Task 12 promotes `SlackWarmCollector` from `public enum` to `public actor`;
//  these statics remain callable on the actor via the same dot syntax.
//
//  Bootstrap discipline: for `userConversationsDiff` the optional prior is the
//  bootstrap signal (`nil` → empty). For the remaining snapshot-array based
//  diffs, an empty prior collection is treated as bootstrap (first observation
//  emits no events; the collector merely writes the snapshot). The collector
//  layer never has to special-case bootstrap — it can simply call the diff
//  helpers every tick.
//

import Foundation

// MARK: - Result types

/// Result of `userConversationsDiff` — channels the authed user joined or
/// left between snapshots. Empty on bootstrap.
public struct SlackUserConversationsDiffResult: Sendable, Hashable {
    public let joined: [SlackMemberChannel]
    public let left: [SlackMemberChannel]

    public init(joined: [SlackMemberChannel], left: [SlackMemberChannel]) {
        self.joined = joined
        self.left = left
    }
}

// MARK: - SlackWarmCollector (placeholder; Task 12 promotes to actor)

public enum SlackWarmCollector {

    /// Pure: rank channels by `latestTs` desc; `nil` latestTs ranks last;
    /// deterministic tie-break on `id` ascending; cap at top-10.
    public static func rankTop10ByLatestTs(
        from channels: [SlackMemberChannel]
    ) -> SlackMemberChannelsTopList {
        let ranked = channels.sorted { l, r in
            switch (l.latestTs, r.latestTs) {
            case let (.some(a), .some(b)):
                if a != b { return a > b }
                return l.id < r.id
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return l.id < r.id
            }
        }
        return SlackMemberChannelsTopList(channels: Array(ranked.prefix(10)))
    }

    /// Pure: derive joined/left events from snapshot diff. Bootstrap (`prior=nil`)
    /// → empty result. Channel identity is the Slack channel id; rename/archive
    /// transitions live on the cold-tier `channelsInfoDiff` instead.
    public static func userConversationsDiff(
        prior: SlackMemberChannelsTopList?,
        current: SlackMemberChannelsTopList
    ) -> SlackUserConversationsDiffResult {
        guard let prior else {
            return SlackUserConversationsDiffResult(joined: [], left: [])
        }
        let priorIDs = Set(prior.channels.map(\.id))
        let currIDs = Set(current.channels.map(\.id))
        let joinedIDs = currIDs.subtracting(priorIDs)
        let leftIDs = priorIDs.subtracting(currIDs)
        let joined = current.channels.filter { joinedIDs.contains($0.id) }
        let left = prior.channels.filter { leftIDs.contains($0.id) }
        return SlackUserConversationsDiffResult(joined: joined, left: left)
    }

    /// Pure: per-channel pin id-set diff. Empty-prior bootstrap → no events.
    /// Channels seen only in `current` (no matching prior row) skip — the
    /// collector treats them as bootstrap-per-channel; subsequent ticks will
    /// have a prior snapshot to diff against.
    public static func pinsPerChannelDiff(
        prior: [SlackChannelPinsSnapshot],
        current: [SlackChannelPinsSnapshot]
    ) -> (added: [(channelID: String, itemRef: String)], removed: [(channelID: String, itemRef: String)]) {
        var added: [(channelID: String, itemRef: String)] = []
        var removed: [(channelID: String, itemRef: String)] = []
        let priorByChannel: [String: SlackChannelPinsSnapshot] =
            Dictionary(uniqueKeysWithValues: prior.map { ($0.channelID, $0) })
        for c in current {
            guard let p = priorByChannel[c.channelID] else { continue }
            let priorRefs = Set(p.pinItemRefs)
            let currRefs = Set(c.pinItemRefs)
            for ref in currRefs.subtracting(priorRefs).sorted() {
                added.append((channelID: c.channelID, itemRef: ref))
            }
            for ref in priorRefs.subtracting(currRefs).sorted() {
                removed.append((channelID: c.channelID, itemRef: ref))
            }
        }
        return (added, removed)
    }

    /// Pure: per-channel bookmarks diff by bookmark `id`. "added" = id present
    /// in current but not prior; "removed" = id present in prior but not current.
    /// Channels seen only in `current` skip (bootstrap-per-channel discipline).
    public static func bookmarksPerChannelDiff(
        prior: [SlackChannelBookmarksSnapshot],
        current: [SlackChannelBookmarksSnapshot]
    ) -> (added: [SlackBookmark], removed: [SlackBookmark]) {
        var added: [SlackBookmark] = []
        var removed: [SlackBookmark] = []
        let priorByChannel: [String: SlackChannelBookmarksSnapshot] =
            Dictionary(uniqueKeysWithValues: prior.map { ($0.channelID, $0) })
        for c in current {
            guard let p = priorByChannel[c.channelID] else { continue }
            let priorByID = Dictionary(uniqueKeysWithValues: p.bookmarks.map { ($0.id, $0) })
            let currByID = Dictionary(uniqueKeysWithValues: c.bookmarks.map { ($0.id, $0) })
            for (id, bm) in currByID where priorByID[id] == nil {
                added.append(bm)
            }
            for (id, bm) in priorByID where currByID[id] == nil {
                removed.append(bm)
            }
        }
        // Deterministic ordering by id for stable downstream tests.
        added.sort { $0.id < $1.id }
        removed.sort { $0.id < $1.id }
        return (added, removed)
    }

    /// Pure: reminders diff. "created" = id newly observed; "completed" = id
    /// present in both, prior.completedTs nil & current.completedTs non-nil.
    /// Empty-prior bootstrap → no events.
    public static func remindersDiff(
        prior: SlackRemindersSnapshot,
        current: SlackRemindersSnapshot
    ) -> (created: [SlackReminder], completed: [SlackReminder]) {
        guard !prior.reminders.isEmpty else { return ([], []) }
        let priorByID = Dictionary(uniqueKeysWithValues: prior.reminders.map { ($0.id, $0) })
        var created: [SlackReminder] = []
        var completed: [SlackReminder] = []
        for r in current.reminders {
            if let p = priorByID[r.id] {
                if p.completedTs == nil && r.completedTs != nil {
                    completed.append(r)
                }
            } else {
                created.append(r)
            }
        }
        created.sort { $0.id < $1.id }
        completed.sort { $0.id < $1.id }
        return (created, completed)
    }

    /// Pure: scheduled messages diff. "scheduled" = id newly observed;
    /// "sent" = id transitioned sent false→true OR id disappeared from current
    /// (Slack drops sent messages from the scheduled list). Empty-prior bootstrap
    /// → no events.
    public static func scheduledMessagesDiff(
        prior: SlackScheduledMessagesSnapshot,
        current: SlackScheduledMessagesSnapshot
    ) -> (scheduled: [SlackScheduledMessage], sent: [SlackScheduledMessage]) {
        guard !prior.messages.isEmpty else { return ([], []) }
        let priorByID = Dictionary(uniqueKeysWithValues: prior.messages.map { ($0.id, $0) })
        let currByID = Dictionary(uniqueKeysWithValues: current.messages.map { ($0.id, $0) })
        var scheduled: [SlackScheduledMessage] = []
        var sent: [SlackScheduledMessage] = []
        for m in current.messages {
            if let p = priorByID[m.id] {
                if !p.sent && m.sent {
                    sent.append(m)
                }
            } else {
                scheduled.append(m)
            }
        }
        // Disappearance ⇒ treat prior (unsent) row as sent.
        for (id, p) in priorByID where currByID[id] == nil && !p.sent {
            sent.append(p)
        }
        scheduled.sort { $0.id < $1.id }
        sent.sort { $0.id < $1.id }
        return (scheduled, sent)
    }

    /// Pure: stars (saved items) diff by itemRef. "saved" = newly observed;
    /// "unsaved" = present in prior, missing in current. Empty-prior bootstrap
    /// → no events.
    public static func starsDiff(
        prior: SlackStarsSnapshot,
        current: SlackStarsSnapshot
    ) -> (saved: [SlackStarItem], unsaved: [SlackStarItem]) {
        guard !prior.stars.isEmpty else { return ([], []) }
        let priorRefs = Set(prior.stars.map(\.itemRef))
        let currRefs = Set(current.stars.map(\.itemRef))
        let savedRefs = currRefs.subtracting(priorRefs)
        let unsavedRefs = priorRefs.subtracting(currRefs)
        let saved = current.stars
            .filter { savedRefs.contains($0.itemRef) }
            .sorted { $0.itemRef < $1.itemRef }
        let unsaved = prior.stars
            .filter { unsavedRefs.contains($0.itemRef) }
            .sorted { $0.itemRef < $1.itemRef }
        return (saved, unsaved)
    }
}
