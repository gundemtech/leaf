//
//  LinearCollector.swift
//  LeafCore
//
//  Phase 4.2 — Linear polling collector. Раз в `intervalSec`:
//  1. Читает `integrations` row (provider=.linear). Если row нет → tick skipped.
//  2. `refresher.refreshIfNeeded(now:)` — обновляет access token если истекает.
//     На `.refreshDenied` (invalid_grant) refresher уже сам делает deleteIntegration
//     + UserDefaults flag + DistributedNotification → UI surface'ит "Reconnect needed".
//  3. `provider.fetchIssues(accessToken:since:)` — GraphQL POST. `since` =
//     stored `lastModifiedMs` cursor; bootstrap → `nil` → provider использует
//     backfill window.
//  4. Map результат в `[RawEvent]` с `signal_type=.action`, `payload.source=linear`.
//  5. Atomic write через `writeEventsAndOffset(events:offset:)` — events + cursor
//     в одной транзакции. Cursor = `batch.cursorMs` (newest updatedAt).
//

import Foundation
import os

public actor LinearCollector {
    /// Phase 4.5 — UserDefaults flag для одноразового wipe старых
    /// (контаминированных teammate-noise) Linear events при первом start
    /// после upgrade. Idempotent: после успешной миграции flag остаётся true,
    /// last-state-wins при повторном start.
    public static let attributionV2MigrationFlagKey = "linear.attribution_v2_migrated"

    private let database: Database
    private let provider: any LinearGraphQLProvider
    private let refresher: LinearTokenRefresher
    private let intervalSec: TimeInterval
    private let backfillWindowDays: Int
    private let logger: Logger
    private let restartTriggerName: String
    /// Phase 4.5 — UserDefaults suite name под Migration flag. Sendable-friendly
    /// (String) — UserDefaults instance строится lazy внутри actor'а. Тесты
    /// передают unique suite ("leaf-test-<UUID>") чтобы изолировать flag от
    /// shared `tech.gundem.leaf` (где живёт production state).
    private let userDefaultsSuiteName: String?

    private var loopTask: Task<Void, Never>?
    private var notifyToken: NSObjectProtocol?

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
        logger.info("LinearCollector started (interval=\(self.intervalSec, privacy: .public)s, backfill=\(self.backfillWindowDays, privacy: .public)d)")
    }

    /// Phase 4.5 — одноразовый wipe Linear events + cursor для перехода на
    /// per-action attribution. Атомарно (transaction в `purgeLinearAttributionV2`),
    /// идемпотентно (UserDefaults flag), не bubble'ит ошибки выше — collector
    /// должен start'ануть даже если миграция fail'нула (например DB locked
    /// другим процессом), retry на следующий start.
    private func runOneTimeMigration() {
        guard !userDefaults.bool(forKey: Self.attributionV2MigrationFlagKey) else { return }
        do {
            let result = try database.purgeLinearAttributionV2()
            userDefaults.set(true, forKey: Self.attributionV2MigrationFlagKey)
            logger.info("Linear attribution_v2 migration: events=\(result.eventsDeleted, privacy: .public) wiped, offsets=\(result.offsetsDeleted, privacy: .public) reset")
        } catch {
            logger.error("Linear attribution_v2 migration failed: \(String(describing: error), privacy: .public) — will retry next start")
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
        /// Phase 4.7.A — linear_comment_authored events emitted в этом tick'е (один per issue с count > 0).
        public let commentEventsEmitted: Int
        /// Phase 4.7.B (B-7) — linear_cycle_progress events emitted в этом tick'е
        /// (один per team с активным cycle'ом). 0 если ни одна команда не in-cycle.
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
            logger.info("tick wrote \(events.count, privacy: .public) events (\(batch.issues.count, privacy: .public) issues + \(batch.transitions.count, privacy: .public) transitions + \(commentEvents.count, privacy: .public) comments + 1 workload pulse + \(cycleEvents.count, privacy: .public) cycle progress), cursor=\(offset.lastModifiedMs, privacy: .public)")
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
            "team_key": issue.teamKey
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
                "period_end_ms": String(periodEndMs)
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
            "top_priority": Self.priorityString(snapshot.topPriority)
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
                "ends_at_ms": String(team.endsAtMs)
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
                "ends_at_ms": team.endsAtMs
            ]
        }
        let firstCycle: [String: Any] = cyclesArray.first ?? [:]

        return [
            "started_issues_count": workload.startedCount,
            "top_priority": Self.priorityString(workload.topPriority),
            "current_cycle": firstCycle,
            "all_team_cycles": cyclesArray,
            "last_touched_issue_id": workload.lastTouchedIdentifier ?? "",
            "last_touched_ts": workload.lastTouchedTs ?? 0
        ]
    }

    /// Maps Linear's int priority enum в string token. 0 ("no priority" в Linear UI)
    /// и nil (workload empty или ни одна issue с priority>0) → "none".
    private static func priorityString(_ value: Int?) -> String {
        switch value {
        case 1: return "urgent"
        case 2: return "high"
        case 3: return "normal"
        case 4: return "low"
        default: return "none"
        }
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
            "transition_at": String(t.transitionAtMs)
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
