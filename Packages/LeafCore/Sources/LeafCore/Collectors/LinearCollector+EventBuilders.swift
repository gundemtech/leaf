//
//  LinearCollector+EventBuilders.swift
//  LeafCore
//
//  Extension split (Phase 2.3.C.3) — static event builders + presence-state
//  composer + priority bucketing. Pure relocation from LinearCollector.swift.
//

import Foundation

extension LinearCollector {
    static func makeEvent(issue: LinearIssueSnapshot) -> RawEvent {
        var payload: [String: String] = [
            "source": "linear",
            "event_kind": "issue_updated",
            "issue_key": issue.issueKey,
            "title": issue.title,
            "status": issue.status,
            "project": issue.project,
            "team_key": issue.teamKey,
        ]
        // Phase 4.6.A.2 — completion duration. Только non-nil → ключ присутствует;
        // отсутствие ключа в payload отличает "не знаем" от "0 секунд" (instant
        // close). SQL aggregator фильтрует `IS NOT NULL`, а не `> 0`, чтобы
        // legitimate zero samples учитывались.
        if let secs = issue.completionSeconds {
            payload["completion_seconds"] = String(secs)
        }
        // Phase 4.7.B (B-8) — cross-provider links derived из Issue.attachments.
        // Omit при zero/nil — same convention что completion_seconds: отсутствие
        // ключа = "no signal", presence ключа = legitimate count (включая edge
        // cases типа issue с attachments к Figma / Notion / external links но без
        // GitHub/Slack — те попадут только в linked_attachment_count).
        if issue.linkedGitHubPRCount > 0 {
            payload["linked_github_pr_count"] = String(issue.linkedGitHubPRCount)
        }
        if let topRepo = issue.linkedGitHubTopRepo {
            payload["linked_github_top_repo"] = topRepo
        }
        if issue.linkedSlackMessageCount > 0 {
            payload["linked_slack_message_count"] = String(issue.linkedSlackMessageCount)
        }
        if issue.linkedAttachmentCount > 0 {
            payload["linked_attachment_count"] = String(issue.linkedAttachmentCount)
        }
        // Phase Track-1 D1 — body / comment bodies / attachment metadata.
        // BodyCap truncation is applied in the provider (LeafCorePrivate moat boundary).
        // Snapshot carries already-capped strings + descriptionTruncated flag.
        // Empty values → key omitted (consistent with existing convention).
        if let desc = issue.description, !desc.isEmpty {
            payload[Schema.EventPayloadKeys.body] = desc
            if issue.descriptionTruncated {
                payload[Schema.EventPayloadKeys.bodyTruncated] = "true"
            }
        }
        if !issue.comments.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(issue.comments),
                let str = String(data: data, encoding: .utf8)
            {
                payload[Schema.EventPayloadKeys.commentBodiesJson] = str
            }
        }
        if !issue.attachments.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(issue.attachments),
                let str = String(data: data, encoding: .utf8)
            {
                payload[Schema.EventPayloadKeys.attachmentsJson] = str
            }
        }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(issue.updatedAtMs) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: payload
        )
    }

    /// Phase 4.7.A — RawEvent для linear_comment_authored aggregate.
    /// Single event per issue per tick, count = моих comments в окне.
    /// ADR-010: bodies НЕ хранятся (provider не запрашивает body вообще).
    static func makeCommentEvent(issue: LinearIssueSnapshot, periodEndMs: Int64) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(periodEndMs) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: [
                "source": "linear",
                "event_kind": "linear_comment_authored",
                "issue_key": issue.issueKey,
                "team_key": issue.teamKey,
                "count_in_window": String(issue.commentCountInWindow),
                "period_end_ms": String(periodEndMs),
            ]
        )
    }

    /// Phase 4.7.B — RawEvent для linear_assigned_workload_pulse.
    /// signalType=.context (это state pulse, не action — describes the *current*
    /// snapshot of viewer's in-flight assigned issues). Emit'ится every tick
    /// including empty workload (startedCount=0) для substrate consistency.
    ///
    /// Payload key conventions:
    /// - `started_count` — всегда present (включая "0").
    /// - `top_priority` — всегда present, string enum: "urgent"/"high"/"normal"/"low"/"none"
    ///   (per plan literal — "none" не omit'ится, чтобы downstream parser не путал
    ///   missing field с "не запросили").
    /// - `last_touched_identifier` / `last_touched_ts_ms` — omit'ятся когда nil
    ///   (consistent с completion_seconds pattern в makeEvent: отсутствие ключа
    ///   = "no sample", не "" / "0" чтобы SQL `IS NOT NULL` корректно фильтровал).
    ///
    /// ADR-010: title issue'а НЕ хранится — даже для lastTouched issue'а; identifier
    /// (e.g. "LEA-123") public-safe (self-authored team key + sequence number).
    static func makeAssignedWorkloadPulseEvent(
        snapshot: LinearAssignedWorkloadSnapshot,
        nowMs: Int64
    ) -> RawEvent {
        var payload: [String: String] = [
            "source": "linear",
            "event_kind": "linear_assigned_workload_pulse",
            "started_count": String(snapshot.startedCount),
            "top_priority": Self.priorityString(snapshot.topPriority),
        ]
        if let id = snapshot.lastTouchedIdentifier {
            payload["last_touched_identifier"] = id
        }
        if let ts = snapshot.lastTouchedTs {
            payload["last_touched_ts_ms"] = String(ts)
        }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000.0),
            signalType: .context,
            bundleID: nil,
            payload: payload
        )
    }

    // MARK: - Phase Track-3 D1 — hot piggy-back emissions

    /// Phase Track-3 D1 — RawEvent for linear_comment_reaction_added.
    /// Provider already filters reactions to viewer's own (user.id == viewer.id).
    static func makeCommentReactionAddedEvent(_ r: LinearCommentReactionSnapshot) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(r.createdAtMs) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: [
                "source": "linear",
                "event_kind": "linear_comment_reaction_added",
                Schema.EventPayloadKeys.commentId: r.commentId,
                Schema.EventPayloadKeys.issueId: r.issueId,
                Schema.EventPayloadKeys.issueIdentifier: r.issueIdentifier,
                Schema.EventPayloadKeys.emoji: r.emoji,
                Schema.EventPayloadKeys.reactedAtMs: String(r.createdAtMs),
            ]
        )
    }

    /// Phase Track-3 D1 — RawEvent for linear_relation_added.
    static func makeRelationAddedEvent(_ r: LinearRelationSnapshot) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(r.transitionedAtMs) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: [
                "source": "linear",
                "event_kind": "linear_relation_added",
                Schema.EventPayloadKeys.relationId: r.id,
                Schema.EventPayloadKeys.fromIssueId: r.fromIssueId,
                Schema.EventPayloadKeys.fromIssueIdentifier: r.fromIssueIdentifier,
                Schema.EventPayloadKeys.toIssueId: r.toIssueId,
                Schema.EventPayloadKeys.toIssueIdentifier: r.toIssueIdentifier,
                Schema.EventPayloadKeys.relationKind: r.relationKind,
                Schema.EventPayloadKeys.startedAtMs: String(r.transitionedAtMs),
            ]
        )
    }

    /// Phase Track-3 D1 — RawEvent for linear_relation_removed.
    static func makeRelationRemovedEvent(_ r: LinearRelationSnapshot) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(r.transitionedAtMs) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: [
                "source": "linear",
                "event_kind": "linear_relation_removed",
                Schema.EventPayloadKeys.relationId: r.id,
                Schema.EventPayloadKeys.fromIssueId: r.fromIssueId,
                Schema.EventPayloadKeys.fromIssueIdentifier: r.fromIssueIdentifier,
                Schema.EventPayloadKeys.toIssueId: r.toIssueId,
                Schema.EventPayloadKeys.toIssueIdentifier: r.toIssueIdentifier,
                Schema.EventPayloadKeys.relationKind: r.relationKind,
                Schema.EventPayloadKeys.removedAtMs: String(r.transitionedAtMs),
            ]
        )
    }

    /// Phase Track-3 D1 — RawEvent for linear_triage_item_picked_up.
    static func makeTriagePickedUpEvent(_ t: LinearTriageTransitionSnapshot) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(t.transitionedAtMs) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: [
                "source": "linear",
                "event_kind": "linear_triage_item_picked_up",
                Schema.EventPayloadKeys.issueId: t.issueId,
                Schema.EventPayloadKeys.issueIdentifier: t.issueIdentifier,
                Schema.EventPayloadKeys.teamId: t.teamId,
                Schema.EventPayloadKeys.toStateName: t.toStateName,
                Schema.EventPayloadKeys.toStateType: t.toStateType,
                Schema.EventPayloadKeys.startedAtMs: String(t.transitionedAtMs),
            ]
        )
    }

    /// Phase Track-3 D1 — RawEvent for linear_triage_item_resolved.
    /// `resolution_kind` ∈ {completed, canceled} from WorkflowState.type.
    static func makeTriageResolvedEvent(_ t: LinearTriageTransitionSnapshot) -> RawEvent {
        var payload: [String: String] = [
            "source": "linear",
            "event_kind": "linear_triage_item_resolved",
            Schema.EventPayloadKeys.issueId: t.issueId,
            Schema.EventPayloadKeys.issueIdentifier: t.issueIdentifier,
            Schema.EventPayloadKeys.teamId: t.teamId,
            Schema.EventPayloadKeys.toStateName: t.toStateName,
            Schema.EventPayloadKeys.toStateType: t.toStateType,
            Schema.EventPayloadKeys.completedAtMs: String(t.transitionedAtMs),
        ]
        if let rk = t.resolutionKind {
            payload[Schema.EventPayloadKeys.resolutionKind] = rk
        }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(t.transitionedAtMs) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: payload
        )
    }

    /// Phase 4.7.B (B-7) — RawEvent для linear_cycle_progress per team.
    /// signalType=.context (cycle progress — state pulse, не action).
    /// Один event per team с активным cycle'ом; teams без cycle'а в provider'е
    /// уже отфильтрованы (`batch.cycles.teams` содержит только in-cycle).
    ///
    /// Payload key conventions (per plan B-7):
    /// - `team_id` / `team_name` / `cycle_id` / `cycle_name` — public-safe metadata.
    /// - `completed_pct` — Double serialized via `String(_:)` (e.g. "80.0"); reader
    ///   parses back с `Double(_:)`.
    /// - `days_remaining` / `scope_count` — Int.
    /// - `starts_at_ms` / `ends_at_ms` — для downstream cycle window queries.
    ///
    /// ADR-010: cycle.description / goals НЕ хранятся (provider их не запрашивает).
    static func makeCycleProgressEvent(
        team: LinearTeamCycleSnapshot,
        nowMs: Int64
    ) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000.0),
            signalType: .context,
            bundleID: nil,
            payload: [
                "source": "linear",
                "event_kind": "linear_cycle_progress",
                "team_id": team.teamID,
                "team_name": team.teamName,
                "cycle_id": team.cycleID,
                "cycle_name": team.cycleName,
                "completed_pct": String(team.completedPct),
                "days_remaining": String(team.daysRemaining),
                "scope_count": String(team.scopeCount),
                "starts_at_ms": String(team.startsAtMs),
                "ends_at_ms": String(team.endsAtMs),
            ]
        )
    }

    /// Phase 4.7.B (B-8) — build composite `presence_state.linear` JSON dict per
    /// plan literal. Combines workload (B-6) + cycles (B-7) snapshots в single
    /// current-state record для presence broadcast (Phase 5) и MCP tools (B-15+).
    ///
    /// Schema:
    /// - `started_issues_count: Int` — derived from workload.startedCount.
    /// - `top_priority: String` — "urgent"/"high"/"normal"/"low"/"none" (always present;
    ///   "none" не omit'ится — downstream parser отличает "не запросили" по отсутствию
    ///   ключа, а "0 in-flight" / "all priority=0" → "none").
    /// - `current_cycle: [String: Any] | {}` — first team's cycle если есть, иначе `{}`.
    ///   Empty dict выбран вместо NSNull чтобы JSON readers могли просто `keys.isEmpty`
    ///   проверить (mirror pattern из B-5: NSNull только для known-nullable scalar fields).
    /// - `all_team_cycles: [[String: Any]]` — array per team с cycle (multi-team support
    ///   для users с >1 team в-cycle simultaneously). Empty array если нет cycles.
    /// - `last_touched_issue_id: String` — workload.lastTouchedIdentifier ?? "".
    /// - `last_touched_ts: Int` — workload.lastTouchedTs ?? 0.
    ///
    /// ADR-010 redaction: только counts / enum strings / self-authored identifiers
    /// (cycle name, team name, issue identifier "LEA-123") + cycle window timestamps.
    /// НЕ хранится: cycle.description, issue.title, comment bodies, attachment titles.
    static func buildLinearPresenceState(
        workload: LinearAssignedWorkloadSnapshot,
        cycles: LinearCycleSnapshot
    ) -> [String: Any] {
        let cyclesArray: [[String: Any]] = cycles.teams.map { team in
            [
                "team_id": team.teamID,
                "team_name": team.teamName,
                "cycle_id": team.cycleID,
                "cycle_name": team.cycleName,
                "completed_pct": team.completedPct,
                "days_remaining": team.daysRemaining,
                "scope_count": team.scopeCount,
                "starts_at_ms": team.startsAtMs,
                "ends_at_ms": team.endsAtMs,
            ]
        }
        let firstCycle: [String: Any] = cyclesArray.first ?? [:]

        return [
            "started_issues_count": workload.startedCount,
            "top_priority": Self.priorityString(workload.topPriority),
            "current_cycle": firstCycle,
            "all_team_cycles": cyclesArray,
            "last_touched_issue_id": workload.lastTouchedIdentifier ?? "",
            "last_touched_ts": workload.lastTouchedTs ?? 0,
        ]
    }

    /// Maps Linear's int priority enum в string token. 0 ("no priority" в Linear UI)
    /// и nil (workload empty или ни одна issue с priority>0) → "none".
    static func priorityString(_ value: Int?) -> String {
        switch value {
        case 1: return "urgent"
        case 2: return "high"
        case 3: return "normal"
        case 4: return "low"
        default: return "none"
        }
    }

    /// Phase 4.7.C — RawEvent для linear_initiative_observed. signalType=.context
    /// (per spec: membership snapshot per tick, не state change). observedAtMs
    /// — момент tick'а, не initiative.updatedAt.
    static func makeInitiativeObservedEvent(_ i: LinearInitiativeSnapshot) -> RawEvent {
        var payload: [String: String] = [
            "source": "linear",
            "event_kind": "linear_initiative_observed",
            "initiative_id": i.initiativeId,
            "name": i.name,
            "observed_at": String(i.observedAtMs),
        ]
        if let s = i.status { payload["status"] = s }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(i.observedAtMs) / 1000.0),
            signalType: .context,
            bundleID: nil,
            payload: payload
        )
    }

    /// Phase 4.7.C — RawEvent для linear_document_edited.
    /// signalType=.action; ADR-010 only document.id + updatedAt + project info? +
    /// title (parity с issue.title); content / preview / body не запрашиваются.
    static func makeDocumentEditedEvent(_ d: LinearDocumentSnapshot) -> RawEvent {
        var payload: [String: String] = [
            "source": "linear",
            "event_kind": "linear_document_edited",
            "document_id": d.documentId,
            "updated_at": String(d.updatedAtMs),
            "title": d.title,
        ]
        if let pid = d.projectId { payload["project_id"] = pid }
        if let pname = d.projectName { payload["project_name"] = pname }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(d.updatedAtMs) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: payload
        )
    }

    /// Phase 4.7.C — RawEvent для my projectUpdate authored.
    /// payload.event_kind="linear_project_update_authored", signalType=.action.
    /// ADR-010: только id + project metadata + health enum; body НЕ включается
    /// (provider не запрашивает, defensive — мы и не формируем).
    static func makeProjectUpdateAuthoredEvent(_ pu: LinearProjectUpdateSnapshot) -> RawEvent {
        var payload: [String: String] = [
            "source": "linear",
            "event_kind": "linear_project_update_authored",
            "update_id": pu.updateId,
            "project_id": pu.projectId,
            "project_name": pu.projectName,
            "created_at": String(pu.createdAtMs),
        ]
        if let h = pu.health { payload["health"] = h }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(pu.createdAtMs) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: payload
        )
    }

    /// Phase 4.7.C — RawEvent для my estimate transition. signalType=.action,
    /// payload.event_kind="linear_estimate_changed". from/to optional Double —
    /// omit'ятся когда nil (parity с cycle event pattern).
    static func makeEstimateTransitionEvent(_ t: LinearEstimateTransitionSnapshot) -> RawEvent {
        var payload: [String: String] = [
            "source": "linear",
            "event_kind": "linear_estimate_changed",
            "issue_key": t.issueKey,
            "history_id": t.historyId,
            "transition_at": String(t.transitionAtMs),
        ]
        if let f = t.fromEstimate { payload["from_estimate"] = String(f) }
        if let to = t.toEstimate { payload["to_estimate"] = String(to) }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(t.transitionAtMs) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: payload
        )
    }

    /// Phase 4.7.C — RawEvent для my cycle transition. signalType=.action,
    /// payload.event_kind="linear_cycle_changed". from/to optional pairs (id+name) —
    /// omit'ятся когда nil (parity с completion_seconds pattern: отсутствие ключа =
    /// "no value", presence ключа = legitimate value).
    static func makeCycleTransitionEvent(_ t: LinearCycleTransitionSnapshot) -> RawEvent {
        var payload: [String: String] = [
            "source": "linear",
            "event_kind": "linear_cycle_changed",
            "issue_key": t.issueKey,
            "history_id": t.historyId,
            "transition_at": String(t.transitionAtMs),
        ]
        if let id = t.fromCycleId { payload["from_cycle_id"] = id }
        if let name = t.fromCycleName { payload["from_cycle_name"] = name }
        if let id = t.toCycleId { payload["to_cycle_id"] = id }
        if let name = t.toCycleName { payload["to_cycle_name"] = name }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(t.transitionAtMs) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: payload
        )
    }

    /// Phase 4.7.C — RawEvent для my assignee transition. signalType=.action,
    /// payload.event_kind="linear_assignee_changed". Bucket — anonymized
    /// self/other (raw third-party IDs не покидают provider'а — ADR-010 PII).
    static func makeAssigneeTransitionEvent(_ t: LinearAssigneeTransitionSnapshot) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(t.transitionAtMs) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: [
                "source": "linear",
                "event_kind": "linear_assignee_changed",
                "issue_key": t.issueKey,
                "history_id": t.historyId,
                "bucket": t.bucket.rawValue,
                "transition_at": String(t.transitionAtMs),
            ]
        )
    }

    /// Phase 4.7.C — RawEvent для my label transition. signalType=.action,
    /// payload.event_kind="linear_label_added" или "linear_label_removed" в
    /// зависимости от `kind`. Один history entry с N добавленных + M удалённых
    /// labels раскладывается parser'ом в N+M snap'ов; collector эмитит N+M
    /// отдельных events.
    /// ADR-010: только label.id + label.name (self-authored, public-safe);
    /// label description / color / created_by / любой text body НЕ запрашиваются.
    static func makeLabelTransitionEvent(_ t: LinearLabelTransitionSnapshot) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(t.transitionAtMs) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: [
                "source": "linear",
                "event_kind": t.kind == .added ? "linear_label_added" : "linear_label_removed",
                "issue_key": t.issueKey,
                "history_id": t.historyId,
                "label_id": t.labelId,
                "label_name": t.labelName,
                "transition_at": String(t.transitionAtMs),
            ]
        )
    }

    /// Phase 4.7.C — RawEvent для my priority transition. signalType=.action,
    /// payload.event_kind="linear_priority_changed" — отдельный flavor от
    /// linear_status_transition. ADR-010: only raw int values + history id +
    /// timestamp; никаких display labels (Linear's "Urgent"/"High"/etc — UI mapping,
    /// derive'ится downstream).
    static func makePriorityTransitionEvent(_ t: LinearPriorityTransitionSnapshot) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(t.transitionAtMs) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: [
                "source": "linear",
                "event_kind": "linear_priority_changed",
                "issue_key": t.issueKey,
                "history_id": t.historyId,
                "from_priority": String(t.fromPriority),
                "to_priority": String(t.toPriority),
                "transition_at": String(t.transitionAtMs),
            ]
        )
    }

    /// Phase 4.6.B — RawEvent для my status transition. signalType=.action,
    /// payload.event_kind="status_transition" — discriminator отделяет от
    /// existing issue_updated events. ADR-010: payload содержит только
    /// public-safe metadata (state names + types + history id).
    static func makeTransitionEvent(_ t: LinearStateTransitionSnapshot) -> RawEvent {
        var payload: [String: String] = [
            "source": "linear",
            "event_kind": "status_transition",
            "issue_key": t.issueKey,
            "history_id": t.historyId,
            "to_state_name": t.toStateName,
            "to_state_type": t.toStateType,
            "transition_at": String(t.transitionAtMs),
        ]
        if let n = t.fromStateName { payload["from_state_name"] = n }
        if let ty = t.fromStateType { payload["from_state_type"] = ty }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(t.transitionAtMs) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: payload
        )
    }
}
