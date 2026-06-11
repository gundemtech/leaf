//
//  LinearCollector.swift
//  LeafCore
//
//  Phase 4.2 — Linear polling collector. Every `intervalSec`:
//  1. Reads the `integrations` row (provider=.linear). If no row → tick skipped.
//  2. `refresher.refreshIfNeeded(now:)` — refreshes the access token if it is expiring.
//     On `.refreshDenied` (invalid_grant) the refresher itself already does deleteIntegration
//     + UserDefaults flag + DistributedNotification → UI surfaces "Reconnect needed".
//  3. `provider.fetchIssues(accessToken:since:)` — GraphQL POST. `since` =
//     stored `lastModifiedMs` cursor; bootstrap → `nil` → provider uses the
//     backfill window.
//  4. Map the result into `[RawEvent]` with `signal_type=.action`, `payload.source=linear`.
//  5. Atomic write via `writeEventsAndOffset(events:offset:)` — events + cursor
//     in one transaction. Cursor = `batch.cursorMs` (newest updatedAt).
//

import Foundation
import os

public actor LinearCollector {
    /// Phase 4.5 — UserDefaults flag for a one-time wipe of old
    /// (teammate-noise-contaminated) Linear events on the first start
    /// after upgrade. Idempotent: after a successful migration the flag stays true,
    /// last-state-wins on a repeated start.
    public static let attributionV2MigrationFlagKey = "linear.attribution_v2_migrated"

    private let database: Database
    private let provider: any LinearGraphQLProvider
    private let refresher: LinearTokenRefresher
    private let intervalSec: TimeInterval
    private let backfillWindowDays: Int
    private let logger: Logger
    private let restartTriggerName: String
    /// Phase 4.5 — UserDefaults suite name for the Migration flag. Sendable-friendly
    /// (String) — the UserDefaults instance is built lazily inside the actor. Tests
    /// pass a unique suite ("leaf-test-<UUID>") to isolate the flag from the
    /// shared `tech.gundem.leaf` (where production state lives).
    private let userDefaultsSuiteName: String?

    private var loopTask: Task<Void, Never>?
    private var notifyToken: NSObjectProtocol?

    /// Track-9 T2 — Linear organization urlKey cache. Populated from
    /// `LinearIssueBatch.workspaceSlug` (extracted by provider parser from the
    /// `viewer.organization { urlKey }` LeafPoll fragment). First non-nil seen
    /// wins; persists across ticks until process restart. Consumed by
    /// `makeCommentToMeEvent` to compose `linear_issue_url` payload field, and
    /// written into `presence_state.linear.workspace_slug` JSON dict key for
    /// cross-process readers.
    private var workspaceSlug: String?

    public init(
        database: Database,
        provider: any LinearGraphQLProvider,
        refresher: LinearTokenRefresher,
        intervalSec: TimeInterval,
        backfillWindowDays: Int,
        restartTriggerName: String = LinearOAuthEndpoints.integrationChangedNotificationName,
        logger: Logger,
        userDefaultsSuiteName: String? = "tech.gundem.leaf"
    ) {
        self.database = database
        self.provider = provider
        self.refresher = refresher
        self.intervalSec = intervalSec
        self.backfillWindowDays = backfillWindowDays
        self.restartTriggerName = restartTriggerName
        self.logger = logger
        self.userDefaultsSuiteName = userDefaultsSuiteName
    }

    private var userDefaults: UserDefaults {
        if let name = userDefaultsSuiteName, let suite = UserDefaults(suiteName: name) {
            return suite
        }
        return .standard
    }

    public func start() {
        guard loopTask == nil else { return }
        runOneTimeMigration()
        let name = NSNotification.Name(restartTriggerName)
        notifyToken = DistributedNotificationCenter.default().addObserver(
            forName: name, object: nil, queue: nil
        ) { [weak self] _ in
            Task { await self?.kickTick() }
        }
        loopTask = Task { [weak self] in await self?.runLoop() }
        logger.info(
            "LinearCollector started (interval=\(self.intervalSec, privacy: .public)s, backfill=\(self.backfillWindowDays, privacy: .public)d)"
        )
    }

    /// Phase 4.5 — one-time wipe of Linear events + cursor for the move to
    /// per-action attribution. Atomic (transaction in `purgeLinearAttributionV2`),
    /// idempotent (UserDefaults flag), does not bubble errors up — the collector
    /// must start even if the migration failed (e.g. DB locked
    /// by another process), retry on the next start.
    private func runOneTimeMigration() {
        guard !userDefaults.bool(forKey: Self.attributionV2MigrationFlagKey) else { return }
        do {
            let result = try database.purgeLinearAttributionV2()
            userDefaults.set(true, forKey: Self.attributionV2MigrationFlagKey)
            logger.info(
                "Linear attribution_v2 migration: events=\(result.eventsDeleted, privacy: .public) wiped, offsets=\(result.offsetsDeleted, privacy: .public) reset"
            )
        } catch {
            logger.error(
                "Linear attribution_v2 migration failed: \(String(describing: error), privacy: .public) — will retry next start"
            )
        }
    }

    public func stop() async {
        loopTask?.cancel()
        await loopTask?.value
        loopTask = nil
        if let t = notifyToken {
            DistributedNotificationCenter.default().removeObserver(t)
            notifyToken = nil
        }
        logger.info("LinearCollector stopped")
    }

    public struct TickResult: Sendable, Equatable {
        public let skipped: Bool
        public let issuesProcessed: Int
        public let cursorAdvancedMs: Int64?
        /// Phase 4.7.A — linear_comment_authored events emitted in this tick (one per issue with count > 0).
        public let commentEventsEmitted: Int
        /// Phase 4.7.B (B-7) — linear_cycle_progress events emitted in this tick
        /// (one per team with an active cycle). 0 if no team is in-cycle.
        public let cycleEventsEmitted: Int

        public init(
            skipped: Bool,
            issuesProcessed: Int,
            cursorAdvancedMs: Int64?,
            commentEventsEmitted: Int = 0,
            cycleEventsEmitted: Int = 0
        ) {
            self.skipped = skipped
            self.issuesProcessed = issuesProcessed
            self.cursorAdvancedMs = cursorAdvancedMs
            self.commentEventsEmitted = commentEventsEmitted
            self.cycleEventsEmitted = cycleEventsEmitted
        }
    }

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

        // 2. Refresh if needed. .refreshDenied → refresher already did
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

        // 5. Map + atomic write. Phase 4.6.B — two event flavors from one batch:
        // (a) issue_updated per touched issue (Phase 4.2 baseline shape),
        // (b) status_transition per my-actor history entry (filter applied in
        //     the provider client-side, see ProdLinearGraphQLProvider.mapStateTransition).
        // Phase 4.7.A — third flavor: linear_comment_authored aggregate per
        // issue with my comments in the tick window (count-only, not per-comment).
        // Phase 4.7.B — fourth flavor: linear_assigned_workload_pulse — single
        // event per tick from batch.workload, signal_type=.context (state pulse,
        // not action). Substrate consistency: emitted EVERY tick including empty
        // workload (startedCount=0) — the downstream aggregator relies on the presence
        // of a sample to distinguish "didn't get to poll" from "user has 0 in-flight".
        // Phase 4.7.B (B-7) — fifth flavor: linear_cycle_progress per team with
        // an active cycle. signal_type=.context. Unlike the workload pulse,
        // emitted conditionally: only for teams with a populated activeCycle
        // (`batch.cycles.teams` is already filtered in the provider). If no team
        // is in-cycle → 0 events (silent).
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        // Boundary re-fetch guard (2026-06-11): Linear evaluates the `$since`
        // DateTime comparison with coarser-than-ms precision server-side, so
        // the issue sitting exactly on the cursor re-returns on EVERY tick.
        // Without this guard each tick re-wrote an identical `issue_updated`
        // row forever (observed: 57 copies of one issue, one per 5-min tick),
        // polluting FTS search, brief counters and the activity feed. An issue
        // whose updatedAt <= cursor has by definition already been captured —
        // drop it before emission. Bootstrap (since == nil) passes everything.
        let freshIssues = since.map { s in batch.issues.filter { $0.updatedAtMs > s } }
            ?? batch.issues
        var events = freshIssues.map { Self.makeEvent(issue: $0) }
        events.append(contentsOf: batch.transitions.map { Self.makeTransitionEvent($0) })
        // Phase 4.7.C — priority transitions per qualified history entry. Mirror
        // status-transition emission shape: signal_type=.action, payload event_kind
        // distinguishes flavor.
        let priorityEvents = batch.priorityTransitions.map { Self.makePriorityTransitionEvent($0) }
        events.append(contentsOf: priorityEvents)
        // Phase 4.7.C — label transitions: one history entry → N+M snaps
        // (added/removed). Each snap → one RawEvent with event_kind="linear_label_added"
        // or "linear_label_removed" (kind enum discriminates).
        let labelEvents = batch.labelTransitions.map { Self.makeLabelTransitionEvent($0) }
        events.append(contentsOf: labelEvents)
        // Phase 4.7.C — assignee transitions (bucketed). Raw assignee IDs do not
        // leave the provider boundary; the collector serializes only the bucket enum.
        let assigneeEvents = batch.assigneeTransitions.map { Self.makeAssigneeTransitionEvent($0) }
        events.append(contentsOf: assigneeEvents)
        // Phase 4.7.C — cycle transitions (added/moved/removed).
        let cycleTransitionEvents = batch.cycleTransitions.map { Self.makeCycleTransitionEvent($0) }
        events.append(contentsOf: cycleTransitionEvents)
        // Phase 4.7.C — estimate transitions (assigned/changed/removed).
        let estimateEvents = batch.estimateTransitions.map { Self.makeEstimateTransitionEvent($0) }
        events.append(contentsOf: estimateEvents)
        // Phase 4.7.C — ProjectUpdate authored events (separate Linear top-level
        // type, piggy-back fragment in the same query).
        let pUpdateEvents = batch.projectUpdates.map { Self.makeProjectUpdateAuthoredEvent($0) }
        events.append(contentsOf: pUpdateEvents)
        // Phase 4.7.C — Document edited events (skeleton; empty on workspaces without
        // feature support).
        let docEvents = batch.documents.map { Self.makeDocumentEditedEvent($0) }
        events.append(contentsOf: docEvents)
        // Phase 4.7.C — Initiative observed events (context signal — membership
        // snapshot per tick, NOT state change). Empty when there is no feature support.
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
        // Track-9 T2 — capture workspaceSlug into actor state BEFORE downstream
        // emission so tick-1 commentToMeEvents include linear_issue_url whenever
        // the batch already carries a valid slug (avoids one-tick degrade gap).
        if let slug = batch.workspaceSlug, !slug.isEmpty {
            self.workspaceSlug = slug
        }
        // Track-9 T2 — discriminator sibling emission. Filter complementary to
        // commentEvents (incoming vs outgoing comments). Same nowMs windowing.
        let commentToMeEvents = batch.issues
            .filter { $0.incomingCommentCount > 0 }
            .map {
                Self.makeCommentToMeEvent(
                    issue: $0, periodEndMs: nowMs, workspaceSlug: self.workspaceSlug)
            }
        events.append(contentsOf: commentToMeEvents)
        let workloadEvent = Self.makeAssignedWorkloadPulseEvent(
            snapshot: batch.workload, nowMs: nowMs
        )
        events.append(workloadEvent)
        let cycleEvents = batch.cycles.teams.map { team in
            Self.makeCycleProgressEvent(team: team, nowMs: nowMs)
        }
        events.append(contentsOf: cycleEvents)
        // If the batch is empty — the cursor does NOT advance (retry next tick on the same since).
        // If the batch is non-empty — cursor = batch.cursorMs (max updatedAt).
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
        // ADR-010 boundary: only counts / public-safe identifiers / enums.
        // No title / description / body gets in (the provider doesn't parse them,
        // building the dict here is defensive — we don't read from event payloads).
        // JSONSerialization-friendly: Int / Double / String / [String: Any]
        // / [[String: Any]]. Optional scalars defaulted to "" / 0 per plan literal
        // (the downstream parser checks startedCount > 0 to distinguish empty from
        // populated, current_cycle dict is empty if there are no in-cycle teams).
        // Track-9 T2 — workspaceSlug already captured into actor state above
        // (before commentToMeEvents emission). Pass cached value to presence
        // dict writer for cross-process readers.
        let linearPresence: [String: Any] = Self.buildLinearPresenceState(
            workload: batch.workload,
            cycles: batch.cycles,
            workspaceSlug: self.workspaceSlug
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

    private static func makeEvent(issue: LinearIssueSnapshot) -> RawEvent {
        var payload: [String: String] = [
            "source": "linear",
            "event_kind": "issue_updated",
            "issue_key": issue.issueKey,
            "title": issue.title,
            "status": issue.status,
            "project": issue.project,
            "team_key": issue.teamKey,
        ]
        // Phase 4.6.A.2 — completion duration. Only non-nil → the key is present;
        // a missing key in the payload distinguishes "don't know" from "0 seconds" (instant
        // close). The SQL aggregator filters on `IS NOT NULL`, not `> 0`, so that
        // legitimate zero samples are counted.
        if let secs = issue.completionSeconds {
            payload["completion_seconds"] = String(secs)
        }
        // Phase 4.7.B (B-8) — cross-provider links derived from Issue.attachments.
        // Omitted on zero/nil — same convention as completion_seconds: a missing
        // key = "no signal", a present key = legitimate count (including edge
        // cases like an issue with attachments to Figma / Notion / external links but without
        // GitHub/Slack — those land only in linked_attachment_count).
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

    /// Phase 4.7.A — RawEvent for the linear_comment_authored aggregate.
    /// Single event per issue per tick, count = my comments in the window.
    /// ADR-010: bodies are NOT stored (the provider doesn't request the body at all).
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

    /// Track-9 T2 — RawEvent for the linear_comment_authored_to_me aggregate.
    /// Discriminator sibling to linear_comment_authored: per-issue count of
    /// comments authored BY OTHERS on this viewer-touched issue during the
    /// polling window (substrate seed for the INBOX `commentOnMyWork` Linear branch).
    ///
    /// `linear_issue_url` field composed from cached `workspaceSlug` +
    /// `issue.issueKey` (public-safe identifiers only). Omitted on cold-tick
    /// before slug cache populates, on Linear free-tier accounts returning null
    /// org, or on defensive empty-string slug. InboxItems deriver sourceURL
    /// gracefully nils out when field missing.
    ///
    /// ADR-010: payload composed exclusively from `workspace_slug` (org
    /// metadata) + `issue_key` (self-authored label) + structured counts /
    /// timestamps. NEVER reads comments[].body / title / description / mention
    /// text. Sentinel-injection test guards the invariant.
    static func makeCommentToMeEvent(
        issue: LinearIssueSnapshot,
        periodEndMs: Int64,
        workspaceSlug: String?
    ) -> RawEvent {
        var payload: [String: String] = [
            "source": "linear",
            "event_kind": "linear_comment_authored_to_me",
            "issue_key": issue.issueKey,
            "team_key": issue.teamKey,
            "to_me_count_in_window": String(issue.incomingCommentCount),
            "period_end_ms": String(periodEndMs),
        ]
        if let slug = workspaceSlug, !slug.isEmpty {
            payload["linear_issue_url"] = "https://linear.app/\(slug)/issue/\(issue.issueKey)"
        }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(periodEndMs) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: payload
        )
    }

    /// Phase 4.7.B — RawEvent for linear_assigned_workload_pulse.
    /// signalType=.context (this is a state pulse, not an action — describes the *current*
    /// snapshot of viewer's in-flight assigned issues). Emitted every tick
    /// including empty workload (startedCount=0) for substrate consistency.
    ///
    /// Payload key conventions:
    /// - `started_count` — always present (including "0").
    /// - `top_priority` — always present, string enum: "urgent"/"high"/"normal"/"low"/"none"
    ///   (per plan literal — "none" is not omitted, so the downstream parser doesn't confuse
    ///   a missing field with "didn't request it").
    /// - `last_touched_identifier` / `last_touched_ts_ms` — omitted when nil
    ///   (consistent with the completion_seconds pattern in makeEvent: a missing key
    ///   = "no sample", not "" / "0" so that SQL `IS NOT NULL` filters correctly).
    ///
    /// ADR-010: the issue title is NOT stored — even for the lastTouched issue; the identifier
    /// (e.g. "LEA-123") is public-safe (self-authored team key + sequence number).
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

    /// Phase 4.7.B (B-7) — RawEvent for linear_cycle_progress per team.
    /// signalType=.context (cycle progress — state pulse, not action).
    /// One event per team with an active cycle; teams without a cycle are already
    /// filtered out in the provider (`batch.cycles.teams` contains only in-cycle ones).
    ///
    /// Payload key conventions (per plan B-7):
    /// - `team_id` / `team_name` / `cycle_id` / `cycle_name` — public-safe metadata.
    /// - `completed_pct` — Double serialized via `String(_:)` (e.g. "80.0"); the reader
    ///   parses it back with `Double(_:)`.
    /// - `days_remaining` / `scope_count` — Int.
    /// - `starts_at_ms` / `ends_at_ms` — for downstream cycle window queries.
    ///
    /// ADR-010: cycle.description / goals are NOT stored (the provider doesn't request them).
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
    /// plan literal. Combines workload (B-6) + cycles (B-7) snapshots into a single
    /// current-state record for presence broadcast (Phase 5) and MCP tools (B-15+).
    ///
    /// Schema:
    /// - `started_issues_count: Int` — derived from workload.startedCount.
    /// - `top_priority: String` — "urgent"/"high"/"normal"/"low"/"none" (always present;
    ///   "none" is not omitted — the downstream parser distinguishes "didn't request it" by a missing
    ///   key, while "0 in-flight" / "all priority=0" → "none").
    /// - `current_cycle: [String: Any] | {}` — first team's cycle if present, else `{}`.
    ///   An empty dict was chosen instead of NSNull so JSON readers can just check
    ///   `keys.isEmpty` (mirror pattern from B-5: NSNull only for known-nullable scalar fields).
    /// - `all_team_cycles: [[String: Any]]` — array per team with a cycle (multi-team support
    ///   for users with >1 team in-cycle simultaneously). Empty array if there are no cycles.
    /// - `last_touched_issue_id: String` — workload.lastTouchedIdentifier ?? "".
    /// - `last_touched_ts: Int` — workload.lastTouchedTs ?? 0.
    ///
    /// ADR-010 redaction: only counts / enum strings / self-authored identifiers
    /// (cycle name, team name, issue identifier "LEA-123") + cycle window timestamps.
    /// NOT stored: cycle.description, issue.title, comment bodies, attachment titles.
    static func buildLinearPresenceState(
        workload: LinearAssignedWorkloadSnapshot,
        cycles: LinearCycleSnapshot,
        workspaceSlug: String? = nil
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
            // Track-9 T2 — Linear organization urlKey for cross-process readers
            // (UI, future MCP tool) that compose linear_issue_url. Empty string
            // on cold-first-tick / free-tier / schema drift — readers gate on
            // non-empty before URL composition.
            "workspace_slug": workspaceSlug ?? "",
        ]
    }

    /// Maps Linear's int priority enum to a string token. 0 ("no priority" in the Linear UI)
    /// and nil (workload empty or no issue with priority>0) → "none".
    private static func priorityString(_ value: Int?) -> String {
        switch value {
        case 1: return "urgent"
        case 2: return "high"
        case 3: return "normal"
        case 4: return "low"
        default: return "none"
        }
    }

    /// Phase 4.7.C — RawEvent for linear_initiative_observed. signalType=.context
    /// (per spec: membership snapshot per tick, not a state change). observedAtMs
    /// — the tick moment, not initiative.updatedAt.
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

    /// Phase 4.7.C — RawEvent for linear_document_edited.
    /// signalType=.action; ADR-010 only document.id + updatedAt + project info? +
    /// title (parity with issue.title); content / preview / body are not requested.
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

    /// Phase 4.7.C — RawEvent for my projectUpdate authored.
    /// payload.event_kind="linear_project_update_authored", signalType=.action.
    /// ADR-010: only id + project metadata + health enum; the body is NOT included
    /// (the provider doesn't request it, defensive — and we don't compose it either).
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

    /// Phase 4.7.C — RawEvent for my estimate transition. signalType=.action,
    /// payload.event_kind="linear_estimate_changed". from/to optional Double —
    /// omitted when nil (parity with the cycle event pattern).
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

    /// Phase 4.7.C — RawEvent for my cycle transition. signalType=.action,
    /// payload.event_kind="linear_cycle_changed". from/to optional pairs (id+name) —
    /// omitted when nil (parity with the completion_seconds pattern: a missing key =
    /// "no value", a present key = legitimate value).
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

    /// Phase 4.7.C — RawEvent for my assignee transition. signalType=.action,
    /// payload.event_kind="linear_assignee_changed". Bucket — anonymized
    /// self/other (raw third-party IDs do not leave the provider — ADR-010 PII).
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

    /// Phase 4.7.C — RawEvent for my label transition. signalType=.action,
    /// payload.event_kind="linear_label_added" or "linear_label_removed" depending
    /// on `kind`. One history entry with N added + M removed
    /// labels is expanded by the parser into N+M snaps; the collector emits N+M
    /// separate events.
    /// ADR-010: only label.id + label.name (self-authored, public-safe);
    /// label description / color / created_by / any text body are NOT requested.
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

    /// Phase 4.7.C — RawEvent for my priority transition. signalType=.action,
    /// payload.event_kind="linear_priority_changed" — a separate flavor from
    /// linear_status_transition. ADR-010: only raw int values + history id +
    /// timestamp; no display labels (Linear's "Urgent"/"High"/etc — a UI mapping,
    /// derived downstream).
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

    /// Phase 4.6.B — RawEvent for my status transition. signalType=.action,
    /// payload.event_kind="status_transition" — the discriminator separates it from
    /// existing issue_updated events. ADR-010: the payload contains only
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

    private func kickTick() async {
        await performTick()
    }

    private func runLoop() async {
        // Initial small delay (cheap startup).
        await sleep(seconds: min(intervalSec, 5))
        while !Task.isCancelled {
            await performTick()
            await sleep(seconds: intervalSec)
        }
    }

    private func sleep(seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}
