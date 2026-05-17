//
//  LinearCollector+Tick.swift
//  LeafCore
//
//  Extension split (Phase 2.3.C.3) — `performTick` orchestration moved out
//  of LinearCollector.swift. Pure relocation; no behavioural change.
//

import Foundation

extension LinearCollector {
    @discardableResult
    public func performTick(now: Date = Date()) async -> TickResult {
        // 1. Read integration row.
        let record: IntegrationRecord?
        do {
            record = try database.readIntegration(provider: .linear)
        } catch {
            logger.error("readIntegration failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: true, issuesProcessed: 0, cursorAdvancedMs: nil)
        }
        guard record != nil else {
            return TickResult(skipped: true, issuesProcessed: 0, cursorAdvancedMs: nil)
        }

        // 2. Refresh if needed. .refreshDenied → refresher уже сделал
        // deleteIntegration + UserDefaults flag + DistributedNotification.
        let refreshed: IntegrationRecord
        do {
            refreshed = try await refresher.refreshIfNeeded(now: now)
        } catch LinearTokenRefresherError.refreshDenied(let msg) {
            logger.warning("refresh denied — Linear disconnected: \(msg, privacy: .public)")
            return TickResult(skipped: true, issuesProcessed: 0, cursorAdvancedMs: nil)
        } catch {
            logger.error("refresh failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: true, issuesProcessed: 0, cursorAdvancedMs: nil)
        }

        // 3. Read cursor.
        let sourceID = "linear:\(refreshed.workspaceID)"
        let stored: CollectorOffset?
        do {
            stored = try database.readOffset(
                collectorID: CollectorID.linearPolling,
                sourceID: sourceID
            )
        } catch {
            logger.error("readOffset failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: true, issuesProcessed: 0, cursorAdvancedMs: nil)
        }
        let since: Int64? = stored?.lastModifiedMs

        // 4. Fetch.
        let batch: LinearIssueBatch
        do {
            batch = try await provider.fetchIssues(
                accessToken: refreshed.accessToken,
                since: since
            )
        } catch {
            logger.error("fetchIssues failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: false, issuesProcessed: 0, cursorAdvancedMs: nil)
        }

        // 5. Map + atomic write. Phase 4.6.B — два event flavors из одного batch:
        // (a) issue_updated per touched issue (Phase 4.2 baseline shape),
        // (b) status_transition per my-actor history entry (filter применён в
        //     провайдере client-side, см. ProdLinearGraphQLProvider.mapStateTransition).
        // Phase 4.7.A — третий flavor: linear_comment_authored aggregate per
        // issue с моими comments в окне tick'а (count-only, не per-comment).
        // Phase 4.7.B — четвёртый flavor: linear_assigned_workload_pulse — single
        // event per tick из batch.workload, signal_type=.context (state pulse,
        // не action). Substrate consistency: emit'ится КАЖДЫЙ tick включая empty
        // workload (startedCount=0) — downstream aggregator опирается на наличие
        // sample, чтобы отличать "не успели poll'нуть" от "у юзера 0 in-flight".
        // Phase 4.7.B (B-7) — пятый flavor: linear_cycle_progress per team с
        // активным cycle'ом. signal_type=.context. В отличие от workload pulse,
        // emit'ится conditionally: только для team'ов с populated activeCycle
        // (`batch.cycles.teams` уже filtered в provider'е). Если ни одна команда
        // не in-cycle → 0 событий (silent).
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        var events = batch.issues.map { Self.makeEvent(issue: $0) }
        events.append(contentsOf: batch.transitions.map { Self.makeTransitionEvent($0) })
        // Phase 4.7.C — priority transitions per qualified history entry. Mirror
        // status-transition emission shape: signal_type=.action, payload event_kind
        // distinguishes flavor.
        let priorityEvents = batch.priorityTransitions.map { Self.makePriorityTransitionEvent($0) }
        events.append(contentsOf: priorityEvents)
        // Phase 4.7.C — label transitions: один history entry → N+M snap'ов
        // (added/removed). Каждый snap → один RawEvent с event_kind="linear_label_added"
        // или "linear_label_removed" (kind enum дискриминирует).
        let labelEvents = batch.labelTransitions.map { Self.makeLabelTransitionEvent($0) }
        events.append(contentsOf: labelEvents)
        // Phase 4.7.C — assignee transitions (bucketed). raw assignee IDs не
        // покидают provider boundary; collector serialize'ит только bucket enum.
        let assigneeEvents = batch.assigneeTransitions.map { Self.makeAssigneeTransitionEvent($0) }
        events.append(contentsOf: assigneeEvents)
        // Phase 4.7.C — cycle transitions (added/moved/removed).
        let cycleTransitionEvents = batch.cycleTransitions.map { Self.makeCycleTransitionEvent($0) }
        events.append(contentsOf: cycleTransitionEvents)
        // Phase 4.7.C — estimate transitions (assigned/changed/removed).
        let estimateEvents = batch.estimateTransitions.map { Self.makeEstimateTransitionEvent($0) }
        events.append(contentsOf: estimateEvents)
        // Phase 4.7.C — ProjectUpdate authored events (separate Linear top-level
        // type, piggy-back fragment в той же query).
        let pUpdateEvents = batch.projectUpdates.map { Self.makeProjectUpdateAuthoredEvent($0) }
        events.append(contentsOf: pUpdateEvents)
        // Phase 4.7.C — Document edited events (skeleton; empty на workspaces без
        // feature support).
        let docEvents = batch.documents.map { Self.makeDocumentEditedEvent($0) }
        events.append(contentsOf: docEvents)
        // Phase 4.7.C — Initiative observed events (context signal — membership
        // snapshot per tick, NOT state change). Empty при отсутствии feature support.
        let initEvents = batch.initiatives.map { Self.makeInitiativeObservedEvent($0) }
        events.append(contentsOf: initEvents)
        // Phase Track-3 D1 — hot piggy-back additions: 5 new event_kinds emitted
        // from the additive LinearIssueBatch arrays added in Task 5. All filtered
        // by viewer.id server-side in the provider (moat — see ProdLinearGraphQLProvider).
        events.append(contentsOf: batch.commentReactions.map(Self.makeCommentReactionAddedEvent))
        events.append(contentsOf: batch.relationAdditions.map(Self.makeRelationAddedEvent))
        events.append(contentsOf: batch.relationRemovals.map(Self.makeRelationRemovedEvent))
        events.append(contentsOf: batch.triagePickedUp.map(Self.makeTriagePickedUpEvent))
        events.append(contentsOf: batch.triageResolved.map(Self.makeTriageResolvedEvent))
        let commentEvents = batch.issues
            .filter { $0.commentCountInWindow > 0 }
            .map { Self.makeCommentEvent(issue: $0, periodEndMs: nowMs) }
        events.append(contentsOf: commentEvents)
        let workloadEvent = Self.makeAssignedWorkloadPulseEvent(
            snapshot: batch.workload, nowMs: nowMs
        )
        events.append(workloadEvent)
        let cycleEvents = batch.cycles.teams.map { team in
            Self.makeCycleProgressEvent(team: team, nowMs: nowMs)
        }
        events.append(contentsOf: cycleEvents)
        // Если batch пуст — cursor НЕ двигается (retry next tick на тех же since).
        // Если batch не пуст — cursor = batch.cursorMs (max updatedAt).
        let advancedCursor = batch.cursorMs ?? since
        let offset = CollectorOffset(
            collectorID: CollectorID.linearPolling,
            sourceID: sourceID,
            byteOffset: 0,
            inode: nil,
            size: 0,
            lastModifiedMs: advancedCursor ?? nowMs,
            updatedMs: nowMs
        )
        // Phase 4.7.B (B-8) — composite presence_state.linear snapshot.
        // ADR-010 boundary: только counts / public-safe identifiers / enums.
        // Никаких title / description / body не попадает (provider их не парсит,
        // build dict здесь — defensive — мы не reading из event payloads).
        // JSONSerialization-friendly: Int / Double / String / [String: Any]
        // / [[String: Any]]. Optional scalars defaulted к "" / 0 per plan literal
        // (downstream parser проверяет startedCount > 0 чтобы отличить empty от
        // populated, current_cycle dict пустой если no in-cycle teams).
        let linearPresence: [String: Any] = Self.buildLinearPresenceState(
            workload: batch.workload,
            cycles: batch.cycles
        )
        do {
            try database.writeEventsOffsetAndPresence(
                events,
                offset: offset,
                presence: (.linear, linearPresence, nil),
                nowMs: nowMs
            )
        } catch {
            logger.error("persist failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: false, issuesProcessed: 0, cursorAdvancedMs: nil)
        }
        if !events.isEmpty {
            logger.info(
                "tick wrote \(events.count, privacy: .public) events (\(batch.issues.count, privacy: .public) issues + \(batch.transitions.count, privacy: .public) transitions + \(commentEvents.count, privacy: .public) comments + 1 workload pulse + \(cycleEvents.count, privacy: .public) cycle progress), cursor=\(offset.lastModifiedMs, privacy: .public)"
            )
        }
        return TickResult(
            skipped: false,
            issuesProcessed: events.count,
            cursorAdvancedMs: advancedCursor,
            commentEventsEmitted: commentEvents.count,
            cycleEventsEmitted: cycleEvents.count
        )
    }
}
