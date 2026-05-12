//
//  SlackColdCollector+Diffs.swift
//  LeafCore
//
//  Phase Track-3 D3 Task 7 — pure static diff helpers for cold-tier (4am
//  local daily) Slack endpoint groups. No IO, no side effects, no logging.
//  Task 14's `SlackColdCollector.performTick` composes these into RawEvent
//  emissions; promotes the type from `public enum` to `public actor`.
//
//  Bootstrap discipline: empty prior snapshot ⇒ first observation, emit
//  nothing (collector just writes the new snapshot). Day-2+ ticks diff.
//

import Foundation

// MARK: - Result types

public struct SlackEmojiDiffResult: Sendable, Hashable {
    public let added: Set<String>

    public init(added: Set<String>) {
        self.added = added
    }
}

// MARK: - SlackColdCollector — static diff helpers (Task 14 promotes the
// type itself to a `public actor` in `SlackColdCollector.swift`; helpers stay
// as `static` methods so they remain composable from the actor body without
// hopping isolation domains).

extension SlackColdCollector {

    /// Pure: canvases diff. "created" = canvasID newly observed; "edited" =
    /// canvasID present in both and `current.lastEditedMs > prior.lastEditedMs`.
    /// Empty-prior bootstrap → no events.
    public static func canvasesPerChannelDiff(
        prior: SlackCanvasesSnapshot,
        current: SlackCanvasesSnapshot
    ) -> (created: [SlackCanvas], edited: [SlackCanvas]) {
        guard !prior.canvases.isEmpty else { return ([], []) }
        let priorByID = Dictionary(uniqueKeysWithValues: prior.canvases.map { ($0.canvasID, $0) })
        var created: [SlackCanvas] = []
        var edited: [SlackCanvas] = []
        for c in current.canvases {
            if let p = priorByID[c.canvasID] {
                if c.lastEditedMs > p.lastEditedMs {
                    edited.append(c)
                }
            } else {
                created.append(c)
            }
        }
        created.sort { $0.canvasID < $1.canvasID }
        edited.sort { $0.canvasID < $1.canvasID }
        return (created, edited)
    }

    /// Pure: custom emoji name set diff. Only "added" surfaces — per spec §2.8
    /// emoji removal is intentionally not a derived event (anti-feature: custom
    /// emoji churn is high and removal is not informative). Empty-prior
    /// bootstrap → no events.
    public static func emojiSetDiff(
        prior: SlackEmojiSnapshot,
        current: SlackEmojiSnapshot
    ) -> SlackEmojiDiffResult {
        guard !prior.emojiNames.isEmpty else {
            return SlackEmojiDiffResult(added: [])
        }
        return SlackEmojiDiffResult(added: current.emojiNames.subtracting(prior.emojiNames))
    }

    /// Pure: usergroups membership diff. For each group present in BOTH prior
    /// and current, derive added/removed userID sets. Groups appearing only in
    /// current (newly observed) or only in prior (group deleted) are skipped —
    /// each is bootstrap-per-group, surfaced upstream as group-creation /
    /// group-deletion via other means if needed. Empty-prior bootstrap → no
    /// events.
    public static func usergroupsDiff(
        prior: SlackUsergroupsSnapshot,
        current: SlackUsergroupsSnapshot
    ) -> [(groupID: String, addedUserIDs: Set<String>, removedUserIDs: Set<String>)] {
        guard !prior.groups.isEmpty else { return [] }
        let priorByID = Dictionary(uniqueKeysWithValues: prior.groups.map { ($0.id, $0) })
        var out: [(groupID: String, addedUserIDs: Set<String>, removedUserIDs: Set<String>)] = []
        for g in current.groups {
            guard let p = priorByID[g.id] else { continue }
            let added = g.userIDs.subtracting(p.userIDs)
            let removed = p.userIDs.subtracting(g.userIDs)
            if !added.isEmpty || !removed.isEmpty {
                out.append((groupID: g.id, addedUserIDs: added, removedUserIDs: removed))
            }
        }
        out.sort { $0.groupID < $1.groupID }
        return out
    }

    /// Pure: channels-info diff. "renamed" = same channelID, different `name`;
    /// "archived" = `isArchived` transitioned false→true. Empty-prior bootstrap
    /// → no events.
    public static func channelsInfoDiff(
        prior: SlackChannelsInfoSnapshot,
        current: SlackChannelsInfoSnapshot
    ) -> (renamed: [(channelID: String, oldName: String, newName: String)], archived: [SlackChannelInfo]) {
        guard !prior.channels.isEmpty else { return ([], []) }
        let priorByID = Dictionary(uniqueKeysWithValues: prior.channels.map { ($0.channelID, $0) })
        var renamed: [(channelID: String, oldName: String, newName: String)] = []
        var archived: [SlackChannelInfo] = []
        for c in current.channels {
            guard let p = priorByID[c.channelID] else { continue }
            if p.name != c.name {
                renamed.append((channelID: c.channelID, oldName: p.name, newName: c.name))
            }
            if !p.isArchived && c.isArchived {
                archived.append(c)
            }
        }
        renamed.sort { $0.channelID < $1.channelID }
        archived.sort { $0.channelID < $1.channelID }
        return (renamed, archived)
    }
}
