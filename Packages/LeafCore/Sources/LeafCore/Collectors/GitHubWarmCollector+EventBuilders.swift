//
//  GitHubWarmCollector+EventBuilders.swift
//  LeafCore
//
//  Extension split (Phase 2.3.C.3) — issue-ref parsing + diff helpers +
//  static event builders for warm-tier GitHub events (ProjectsV2 / Gists /
//  Invitations / Codespaces / IssueReactions). Pure relocation from
//  GitHubWarmCollector.swift.
//

import Foundation

extension GitHubWarmCollector {
    // MARK: - Issue-ref parsing

    static func parseIssueRef(_ ref: String) -> (owner: String, repo: String, number: Int)? {
        // Expected form: "owner/repo#NN"
        guard let hashIdx = ref.firstIndex(of: "#") else { return nil }
        let repoPart = ref[..<hashIdx]
        let numberPart = ref[ref.index(after: hashIdx)...]
        let slashes = repoPart.split(separator: "/", maxSplits: 1)
        guard slashes.count == 2, let number = Int(numberPart) else { return nil }
        return (String(slashes[0]), String(slashes[1]), number)
    }

    // MARK: - Diff helpers

    /// projectsV2Diff lives at the top of this file (Task 7 shipped it as the
    /// pure helper consumed by performTick). The doc comment + impl remain
    /// untouched — they document the bootstrap discipline + sort order
    /// contract that tests exercise.
    /// Card moved between status columns. `itemID` + `projectID` identify the
    /// project-v2 item; `oldStatus` / `newStatus` capture the column transition
    /// (either side may be nil — backlog/done columns commonly have no value).
    public struct ProjectV2CardMoved: Sendable, Equatable {
        public let itemID: String
        public let projectID: String
        public let oldStatus: String?
        public let newStatus: String?
    }

    /// Card iteration assignment changed. `itemID` + `projectID` identify the
    /// item; `oldIteration` / `newIteration` capture the iteration ref shift.
    public struct ProjectV2IterationChanged: Sendable, Equatable {
        public let itemID: String
        public let projectID: String
        public let oldIteration: String?
        public let newIteration: String?
    }

    /// Per-field value change on a project-v2 item. `fieldName` is the
    /// project-v2 custom-field title; `oldValue` / `newValue` are the prior
    /// / current opaque value (either side may be nil for adds/clears).
    public struct ProjectV2FieldUpdated: Sendable, Equatable {
        public let itemID: String
        public let projectID: String
        public let fieldName: String
        public let oldValue: String?
        public let newValue: String?
    }

    public static func projectsV2Diff(
        prior: [GitHubProjectV2ItemSnapshot],
        current: [GitHubProjectV2ItemSnapshot]
    ) -> (
        cardMoved: [ProjectV2CardMoved],
        iterationChanged: [ProjectV2IterationChanged],
        fieldUpdated: [ProjectV2FieldUpdated]
    ) {
        let priorByID = Dictionary(uniqueKeysWithValues: prior.map { ($0.itemID, $0) })
        var cardMoved: [ProjectV2CardMoved] = []
        var iter: [ProjectV2IterationChanged] = []
        var fields: [ProjectV2FieldUpdated] = []
        for curr in current {
            guard let p = priorByID[curr.itemID] else { continue }
            if p.status != curr.status {
                cardMoved.append(ProjectV2CardMoved(
                    itemID: curr.itemID, projectID: curr.projectID,
                    oldStatus: p.status, newStatus: curr.status
                ))
            }
            if p.iterationID != curr.iterationID {
                iter.append(ProjectV2IterationChanged(
                    itemID: curr.itemID, projectID: curr.projectID,
                    oldIteration: p.iterationID, newIteration: curr.iterationID
                ))
            }
            let allFieldNames = Set(p.fieldValues.keys).union(curr.fieldValues.keys)
            for name in allFieldNames.sorted() {
                let oldV = p.fieldValues[name]
                let newV = curr.fieldValues[name]
                if oldV != newV {
                    fields.append(ProjectV2FieldUpdated(
                        itemID: curr.itemID, projectID: curr.projectID,
                        fieldName: name, oldValue: oldV, newValue: newV
                    ))
                }
            }
        }
        return (
            cardMoved.sorted(by: { $0.itemID < $1.itemID }),
            iter.sorted(by: { $0.itemID < $1.itemID }),
            fields.sorted(by: { $0.itemID == $1.itemID ? $0.fieldName < $1.fieldName : $0.itemID < $1.itemID })
        )
    }

    /// Gist diff partitions current snapshot vs prior into create / update /
    /// delete buckets, keyed by `gistID`. Update detection uses `updatedAtMs`
    /// strict inequality — descriptions changing without timestamp bump are
    /// trusted to not represent a real edit.
    public static func gistsDiff(
        prior: [GitHubGistSnapshot],
        current: [GitHubGistSnapshot]
    ) -> (created: [GitHubGistSnapshot], updated: [GitHubGistSnapshot], deleted: [GitHubGistSnapshot]) {
        let priorByID = Dictionary(uniqueKeysWithValues: prior.map { ($0.gistID, $0) })
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.gistID, $0) })
        var created: [GitHubGistSnapshot] = []
        var updated: [GitHubGistSnapshot] = []
        var deleted: [GitHubGistSnapshot] = []
        for c in current {
            if let p = priorByID[c.gistID] {
                if p.updatedAtMs != c.updatedAtMs {
                    updated.append(c)
                }
            } else {
                created.append(c)
            }
        }
        for p in prior where currentByID[p.gistID] == nil {
            deleted.append(p)
        }
        return (
            created.sorted(by: { $0.gistID < $1.gistID }),
            updated.sorted(by: { $0.gistID < $1.gistID }),
            deleted.sorted(by: { $0.gistID < $1.gistID })
        )
    }

    /// Invitation diff: received = present in current but not prior; accepted =
    /// present in prior but absent from current (treated as accepted/cleared;
    /// explicit decline distinction lives in cold-tier audit log if surfaced).
    public static func invitationsDiff(
        prior: [GitHubRepoInvitationSnapshot],
        current: [GitHubRepoInvitationSnapshot]
    ) -> (received: [GitHubRepoInvitationSnapshot], accepted: [GitHubRepoInvitationSnapshot]) {
        let priorByID = Dictionary(uniqueKeysWithValues: prior.map { ($0.invitationID, $0) })
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.invitationID, $0) })
        let received =
            current
            .filter { priorByID[$0.invitationID] == nil }
            .sorted(by: { $0.invitationID < $1.invitationID })
        let accepted =
            prior
            .filter { currentByID[$0.invitationID] == nil }
            .sorted(by: { $0.invitationID < $1.invitationID })
        return (received, accepted)
    }

    /// Result of ``codespacesDiff(prior:current:)`` partitioned into four
    /// mutually-exclusive buckets. `created` = new codespace name; `started`
    /// = state transitioned to `Available`; `stopped` = transitioned to
    /// `Shutdown`; `deleted` = name absent from current. Transient states
    /// (Provisioning / Queued / Building / Starting / etc) leave all buckets
    /// untouched.
    public struct CodespacesDiff: Sendable, Equatable {
        public let created: [GitHubCodespaceSnapshot]
        public let started: [GitHubCodespaceSnapshot]
        public let stopped: [GitHubCodespaceSnapshot]
        public let deleted: [GitHubCodespaceSnapshot]
    }

    /// Codespace diff: created = new codespace name; started = state
    /// transitioned to `Available`; stopped = transitioned to `Shutdown`;
    /// deleted = name absent from current. Transient states (Provisioning /
    /// Queued / Building / Starting / etc) emit nothing.
    public static func codespacesDiff(
        prior: [GitHubCodespaceSnapshot],
        current: [GitHubCodespaceSnapshot]
    ) -> CodespacesDiff {
        let priorByName = Dictionary(uniqueKeysWithValues: prior.map { ($0.codespaceName, $0) })
        let currentByName = Dictionary(uniqueKeysWithValues: current.map { ($0.codespaceName, $0) })
        var created: [GitHubCodespaceSnapshot] = []
        var started: [GitHubCodespaceSnapshot] = []
        var stopped: [GitHubCodespaceSnapshot] = []
        var deleted: [GitHubCodespaceSnapshot] = []
        for c in current {
            if let p = priorByName[c.codespaceName] {
                if p.state != c.state {
                    if c.state == "Available" {
                        started.append(c)
                    } else if c.state == "Shutdown" {
                        stopped.append(c)
                    }
                }
            } else {
                created.append(c)
            }
        }
        for p in prior where currentByName[p.codespaceName] == nil {
            deleted.append(p)
        }
        return CodespacesDiff(
            created: created.sorted(by: { $0.codespaceName < $1.codespaceName }),
            started: started.sorted(by: { $0.codespaceName < $1.codespaceName }),
            stopped: stopped.sorted(by: { $0.codespaceName < $1.codespaceName }),
            deleted: deleted.sorted(by: { $0.codespaceName < $1.codespaceName })
        )
    }

    /// Reactions diff: per-emoji (oldCount, newCount) pairs. Collector emits
    /// `reaction_received` only when `newCount > oldCount` (positive delta) —
    /// reaction removals are silent.
    public static func reactionsDiff(
        prior: GitHubIssueReactionsSnapshot,
        current: GitHubIssueReactionsSnapshot
    ) -> [(emoji: String, oldCount: Int, newCount: Int)] {
        let emojis = Set(prior.byEmoji.keys).union(current.byEmoji.keys).sorted()
        var out: [(emoji: String, oldCount: Int, newCount: Int)] = []
        for emoji in emojis {
            let old = prior.byEmoji[emoji] ?? 0
            let new = current.byEmoji[emoji] ?? 0
            if old != new {
                out.append((emoji, old, new))
            }
        }
        return out
    }

    // MARK: - Event builders

    static func makeProjectCardMovedEvent(
        itemID: String, projectID: String,
        oldStatus: String?, newStatus: String?, observedAtMs: Int64
    ) -> RawEvent {
        var payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.projectCardMoved.rawValue,
            Schema.EventPayloadKeys.projectV2CardId: itemID,
            Schema.EventPayloadKeys.projectV2Id: projectID,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs),
        ]
        if let s = oldStatus { payload[Schema.EventPayloadKeys.projectV2OldValue] = s }
        if let s = newStatus { payload[Schema.EventPayloadKeys.projectV2NewValue] = s }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .action, bundleID: nil, payload: payload
        )
    }

    static func makeProjectIterationChangedEvent(
        itemID: String, projectID: String,
        oldIteration: String?, newIteration: String?, observedAtMs: Int64
    ) -> RawEvent {
        var payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.projectIterationChanged.rawValue,
            Schema.EventPayloadKeys.projectV2CardId: itemID,
            Schema.EventPayloadKeys.projectV2Id: projectID,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs),
        ]
        if let s = oldIteration { payload[Schema.EventPayloadKeys.projectV2OldValue] = s }
        if let s = newIteration { payload[Schema.EventPayloadKeys.projectV2NewValue] = s }
        if let s = newIteration { payload[Schema.EventPayloadKeys.iterationId] = s }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .action, bundleID: nil, payload: payload
        )
    }

    static func makeProjectFieldUpdatedEvent(
        itemID: String, projectID: String, fieldName: String,
        oldValue: String?, newValue: String?, observedAtMs: Int64
    ) -> RawEvent {
        var payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.projectFieldUpdated.rawValue,
            Schema.EventPayloadKeys.projectV2CardId: itemID,
            Schema.EventPayloadKeys.projectV2Id: projectID,
            Schema.EventPayloadKeys.projectV2FieldName: fieldName,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs),
        ]
        if let s = oldValue { payload[Schema.EventPayloadKeys.projectV2OldValue] = s }
        if let s = newValue { payload[Schema.EventPayloadKeys.projectV2NewValue] = s }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .action, bundleID: nil, payload: payload
        )
    }

    static func makeGistCreatedEvent(_ g: GitHubGistSnapshot, observedAtMs: Int64) -> RawEvent {
        let payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.gistCreated.rawValue,
            Schema.EventPayloadKeys.gistId: g.gistID,
            Schema.EventPayloadKeys.gistDescription: g.description,
            // Mirror description under canonical `body` key so EventsFullTextStore
            // picks it up (body_kind `gh_gist_description`, Task 25 wiring).
            Schema.EventPayloadKeys.body: g.description,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs),
        ]
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .action, bundleID: nil, payload: payload
        )
    }

    static func makeGistUpdatedEvent(_ g: GitHubGistSnapshot, observedAtMs: Int64) -> RawEvent {
        let payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.gistUpdated.rawValue,
            Schema.EventPayloadKeys.gistId: g.gistID,
            Schema.EventPayloadKeys.gistDescription: g.description,
            Schema.EventPayloadKeys.body: g.description,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs),
        ]
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .action, bundleID: nil, payload: payload
        )
    }

    static func makeGistDeletedEvent(_ g: GitHubGistSnapshot, observedAtMs: Int64) -> RawEvent {
        // No body payload — description not preserved on deletion (snapshot is
        // gone; rebuilding from prior would lift moat'ed text into a fresh
        // event, which the spec disallows for the deletion event).
        let payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.gistDeleted.rawValue,
            Schema.EventPayloadKeys.gistId: g.gistID,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs),
        ]
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .action, bundleID: nil, payload: payload
        )
    }

    static func makeRepoInvitationReceivedEvent(
        _ inv: GitHubRepoInvitationSnapshot, observedAtMs: Int64
    ) -> RawEvent {
        let payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.repoInvitationReceived.rawValue,
            Schema.EventPayloadKeys.repoInvitationId: inv.invitationID,
            Schema.EventPayloadKeys.repoFullName: inv.repoFullName,
            Schema.EventPayloadKeys.repoInvitationFromLogin: inv.inviterLogin,
            Schema.EventPayloadKeys.receivedAtMs: String(inv.invitedAtMs),
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs),
        ]
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .context, bundleID: nil, payload: payload
        )
    }

    static func makeRepoInvitationAcceptedEvent(
        _ inv: GitHubRepoInvitationSnapshot, observedAtMs: Int64
    ) -> RawEvent {
        let payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.repoInvitationAccepted.rawValue,
            Schema.EventPayloadKeys.repoInvitationId: inv.invitationID,
            Schema.EventPayloadKeys.repoFullName: inv.repoFullName,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs),
        ]
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .action, bundleID: nil, payload: payload
        )
    }

    static func makeCodespaceCreatedEvent(_ c: GitHubCodespaceSnapshot, observedAtMs: Int64) -> RawEvent {
        let payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.codespaceCreated.rawValue,
            Schema.EventPayloadKeys.codespaceName: c.codespaceName,
            Schema.EventPayloadKeys.repoFullName: c.repoFullName,
            Schema.EventPayloadKeys.codespaceState: c.state,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs),
        ]
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .action, bundleID: nil, payload: payload
        )
    }

    static func makeCodespaceStartedEvent(_ c: GitHubCodespaceSnapshot, observedAtMs: Int64) -> RawEvent {
        let payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.codespaceStarted.rawValue,
            Schema.EventPayloadKeys.codespaceName: c.codespaceName,
            Schema.EventPayloadKeys.repoFullName: c.repoFullName,
            Schema.EventPayloadKeys.codespaceState: c.state,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs),
        ]
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .action, bundleID: nil, payload: payload
        )
    }

    static func makeCodespaceStoppedEvent(_ c: GitHubCodespaceSnapshot, observedAtMs: Int64) -> RawEvent {
        let payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.codespaceStopped.rawValue,
            Schema.EventPayloadKeys.codespaceName: c.codespaceName,
            Schema.EventPayloadKeys.repoFullName: c.repoFullName,
            Schema.EventPayloadKeys.codespaceState: c.state,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs),
        ]
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .action, bundleID: nil, payload: payload
        )
    }

    static func makeCodespaceDeletedEvent(_ c: GitHubCodespaceSnapshot, observedAtMs: Int64) -> RawEvent {
        let payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.codespaceDeleted.rawValue,
            Schema.EventPayloadKeys.codespaceName: c.codespaceName,
            Schema.EventPayloadKeys.repoFullName: c.repoFullName,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs),
        ]
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .action, bundleID: nil, payload: payload
        )
    }

    static func makeIssueReactionReceivedEvent(
        _ snap: GitHubIssueReactionsSnapshot, emoji: String, delta: Int, observedAtMs: Int64
    ) -> RawEvent {
        let payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.issueReactionReceived.rawValue,
            Schema.EventPayloadKeys.repoFullName: "\(snap.owner)/\(snap.repo)",
            "issue_number": String(snap.issueNumber),
            Schema.EventPayloadKeys.reactionEmoji: emoji,
            Schema.EventPayloadKeys.reactionCount: String(snap.byEmoji[emoji] ?? 0),
            Schema.EventPayloadKeys.reactionDelta: String(delta),
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs),
        ]
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .context, bundleID: nil, payload: payload
        )
    }
}
