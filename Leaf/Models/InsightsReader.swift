//
//  InsightsReader.swift
//  Leaf
//
//  @Observable state-machine для MenuBarContent: открывает events.sqlite
//  в reader-режиме, зовёт Derived Insights (timeInApp за "today") и отдаёт
//  результат в UI. Управление параллельными refresh'ами, обработка
//  отсутствующей базы, логирование ошибок через os.Logger.
//

import Foundation
import LeafCore
import OSLog
import Observation

#if LEAF_PROD
import LeafCorePrivate
#endif

// Note: `#if LEAF_PROD import LeafCorePrivate` остаётся здесь
// чтобы `ProdConfigs.database` резолвился в `defaultConfig()`. Provider
// для insights регистрируется отдельно, в `LeafApp.init()`.

@MainActor
@Observable
final class InsightsReader {
    enum State {
        case notConfigured(message: String)
        case loading
        case loaded(snapshot: InsightsSnapshot, updated: Date)
        case empty(message: String)
        case error(message: String)
    }

    private(set) var state: State = .loading

    private var database: LeafCore.Database?
    private var currentTask: Task<Void, Never>?

    private let databaseURL: URL
    private let databaseConfig: DatabaseConfig
    private let databaseEncryption: EncryptionOptions?
    /// Threshold "deep" — берётся из ProdConfigs (LEAF_PROD) или weakDefaults.
    /// Применяется на producer-side при сборке snapshot, UI не пересчитывает.
    private let deepSessionMinSec: TimeInterval
    private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "insights")

    init(
        databaseURL: URL = DatabasePath.defaultURL(),
        databaseConfig: DatabaseConfig = InsightsReader.defaultConfig(),
        databaseEncryption: EncryptionOptions? = InsightsReader.defaultEncryption(),
        deepSessionMinSec: TimeInterval = InsightsReader.defaultDeepSessionMinSec()
    ) {
        self.databaseURL = databaseURL
        self.databaseConfig = databaseConfig
        self.databaseEncryption = databaseEncryption
        self.deepSessionMinSec = deepSessionMinSec
    }

    func refresh() {
        // Cancel previous refresh'ы — защита от race при быстрых повторных
        // открытиях popover'а (P6 в плане).
        currentTask?.cancel()

        // Pre-check существования файла — избегаем exception overhead и
        // даём осмысленный .notConfigured state вместо обобщённой ошибки (P9).
        if !FileManager.default.fileExists(atPath: databaseURL.path) {
            state = .notConfigured(
                message: "Enable background collection in Settings to see today's activity."
            )
            return
        }

        state = .loading
        let url = databaseURL
        let cfg = databaseConfig
        let enc = databaseEncryption
        let cachedDB = database
        let deepMin = deepSessionMinSec

        currentTask = Task { [self] in
            // Database (@unchecked Sendable) и InsightsSnapshot (Sendable) —
            // hopping через MainActor.run после background compute race-safe.
            let result: Result<(LeafCore.Database, InsightsSnapshot), Error> =
                await Task.detached(priority: .userInitiated) {
                    do {
                        let db = try cachedDB ?? LeafCore.Database.openForRead(at: url, config: cfg, encryption: enc)
                        let insights = DerivedInsightsFactory.make(database: db)
                        let today = Self.todayInterval()
                        // Sequential calls — async overhead неоправдан, SQL-reads <50ms.
                        let topApps = try insights.timeInApp(period: today)
                        try Task.checkCancellation()
                        let sessions = try insights.focusSessions(period: today)
                        try Task.checkCancellation()
                        let switchRate = try insights.contextSwitchRate(period: today)
                        try Task.checkCancellation()
                        // Phase 2.2 trends — 4 независимых queries, sequential
                        // (каждый < 50ms на типичном workload'е; если p95 вырастет
                        // под нагрузкой — оптимизируем в 2.5 wrap через shared CTE).
                        let streak = try insights.deepWorkStreak()
                        try Task.checkCancellation()
                        let peakHour = try insights.peakProductivityHour()
                        try Task.checkCancellation()
                        let wow = try insights.weekOverWeekDelta()
                        try Task.checkCancellation()
                        let activeDays = try insights.activeDaysInRow()
                        try Task.checkCancellation()
                        // Phase 2.3 — AI breakdown за тот же `today` period.
                        // 8-я sequential query; если совокупный p95 вырастет —
                        // оптимизация в 2.5 wrap (shared CTE для bucket'ов).
                        let aiBreakdown = try insights.aiActivityBreakdown(period: today)
                        try Task.checkCancellation()
                        // Phase 2.4 — top files touched в watched folders.
                        // 9-я sequential query; lazy на пустой content events
                        // (router StubFSEventsRouter в CI всегда .filtered → []).
                        let filesTouched = try insights.filesTouched(period: today)
                        try Task.checkCancellation()
                        // Phase 4.2 — Linear issue activity.
                        // 10-я sequential query; на не-подключённом Linear возвращает
                        // .empty (Stub) — popover'у решать рендерить или скрыть.
                        let linear = try insights.linearActivity(period: today)
                        try Task.checkCancellation()
                        // Phase 4.3 — GitHub events activity. 11-я sequential query;
                        // на не-подключённом GitHub возвращает .empty (Stub).
                        let github = try insights.githubActivity(period: today)
                        try Task.checkCancellation()
                        // Phase 4.4 — Slack activity. 12-я sequential query;
                        // на не-подключённом Slack возвращает .empty (Stub).
                        let slack = try insights.slackActivity(period: today)
                        try Task.checkCancellation()
                        // Phase 4.6.C.2 — longest gap без Layer B events.
                        // 13-я sequential query; default impl = nil (StubInsights),
                        // поэтому popover просто не рендерит row.
                        let uninterruptedWindow = try insights.longestUninterruptedWindow(period: today)
                        try Task.checkCancellation()
                        // Phase 4.10.A — chronological per-event feed для Activity tab.
                        // 14-я sequential query; default impl = [] (StubInsights),
                        // поэтому Activity tab рендерит empty state на CI / no-prod.
                        let recentActivity = try insights.recentActivity(period: today, limit: 200)
                        try Task.checkCancellation()
                        // Phase 4.10.B — aggregated sessions для Activity tab
                        // ("Sessions" mode) и Home Recent Sessions block. Default
                        // impl = [] (StubInsights / pre-prod), поэтому UI просто
                        // не рендерит блок если sessions пустые.
                        let recentSessions = try insights.recentSessions(period: today, limit: 200)
                        try Task.checkCancellation()
                        // Phase 4.10.A — Live Presence widget читает merged
                        // presence_state row-ы (single-row-per-provider materialized
                        // view, no period). Empty pre-4.7 install / non-prod CI.
                        let presenceState: PresenceUISnapshot = (try? PresenceUISnapshot.read(database: db)) ?? .empty
                        try Task.checkCancellation()
                        // Track-8 Phase 8.3 — TODAY block aggregates (focused
                        // minutes / AI ratio / sessions / switches / commits +
                        // surface pills). Single SQL call backed by Phase 8.1
                        // substrate; stub on non-prod returns .empty.
                        let todayMetrics = try insights.todayMetrics(now: Date())
                        try Task.checkCancellation()
                        // Track-8 Phase 8.4 — YOU·NOW dashboard cell state.
                        // Single deriver call over the same substrate
                        // (presence_state + attention / meeting / focus /
                        // screen-lock transitions). Stub returns .empty.
                        let youNowState = try insights.youNowState(now: Date())
                        try Task.checkCancellation()
                        // Track-8 Phase 8.5 — same-task teammates list.
                        // Hierarchical rule (same Linear → same branch →
                        // adjacent branch). Stub reader returns [] until
                        // Phase 5.4 wires DBTeammatePresenceReader against
                        // presence_history; block renders empty state
                        // until then.
                        let sameTaskTeammates = try insights.sameTaskTeammates(rule: .hierarchical)
                        try Task.checkCancellation()
                        // Track-8 Phase 8.6 — INBOX dashboard items list.
                        // Fetched with .all/"" defaults; filter + search
                        // applied view-side as @State, no re-fetch on
                        // keystroke. Stub returns [] until Phase 4.8/4.9
                        // wire Layer B; D3 detection tables already feed
                        // open questions + blockers via the moat impl.
                        let inboxItems = try insights.inboxItems(filter: .all, query: "")
                        try Task.checkCancellation()
                        // Track-8 Phase 8.7 — WHERE STOPPED block snapshot.
                        // Take first (most recent) row; substrate returns
                        // most-recent-first per `ProdWhereStoppedDeriver`.
                        // `nil` when substrate has no row (fresh DB, idle
                        // gate not met, or non-prod StubInsights).
                        let whereStopped = try insights.recentWhereStopped(limit: 1).first
                        try Task.checkCancellation()
                        let snapshot = InsightsSnapshot(
                            topApps: topApps,
                            sessions: sessions,
                            switchRate: switchRate,
                            deepSessionMinSec: deepMin,
                            deepWorkStreak: streak,
                            peakProductivityHour: peakHour,
                            weekOverWeekDelta: wow,
                            activeDaysInRow: activeDays,
                            aiRatio: aiBreakdown.ratio,
                            aiActiveSeconds: aiBreakdown.aiActiveSeconds,
                            filesTouched: filesTouched,
                            linearIssuesTouched: linear.issuesTouched,
                            linearByProject: linear.byProject,
                            linearByStatus: linear.byStatus,
                            linearCompletionDurationStats: linear.completionDurationStats,
                            githubEventsCount: github.eventsCount,
                            githubByRepo: github.byRepo,
                            githubByEventKind: github.byEventKind,
                            githubPRCycleStats: github.prCycleStats,
                            githubReviewDelayStats: github.reviewDelayStats,
                            slackMessagesCount: slack.messagesCount,
                            slackHuddleMinutes: slack.huddleMinutes,
                            slackByChannel: slack.byChannel,
                            slackReactionsReceived: slack.reactionsReceived ?? 0,
                            slackHuddleSessionStats: slack.huddleSessionStats,
                            longestUninterruptedWindow: uninterruptedWindow,
                            linearIssueCloseStreak: linear.issueCloseStreak ?? 0,
                            githubCommitStreak: github.commitStreak ?? 0,
                            slackHuddleParticipationStreak: slack.huddleParticipationStreak ?? 0,
                            // Phase 4.6.B — passthrough из linearActivity (third
                            // read внутри). Snapshot mirror'ит для UI/MCP consumers.
                            linearTransitions: linear.transitions,
                            linearCompletionRate: linear.completionRate,
                            recentActivity: recentActivity,
                            presenceState: presenceState,
                            recentSessions: recentSessions,
                            todayMetrics: todayMetrics,
                            youNowState: youNowState,
                            sameTaskTeammates: sameTaskTeammates,
                            inboxItems: inboxItems,
                            whereStopped: whereStopped
                        )
                        return .success((db, snapshot))
                    } catch {
                        return .failure(error)
                    }
                }.value

            if Task.isCancelled { return }

            switch result {
            case .success(let (db, snapshot)):
                self.database = db
                if snapshot.isEmpty {
                    self.state = .empty(
                        message: "Collecting… activity will appear after a few app switches."
                    )
                } else {
                    self.state = .loaded(snapshot: snapshot, updated: Date())
                }
            case .failure(let error):
                if error is CancellationError { return }
                // Детально логируем (os.Logger → Console.app), в UI
                // только generic сообщение (P8 — moat-safe).
                self.logger.error("insights snapshot failed: \(String(describing: error), privacy: .public)")
                self.database = nil
                self.state = .error(
                    message: "Couldn't read today's activity. Try Refresh."
                )
            }
        }
    }

    // Track-7 — exposed to internal callers (ClaudeCodeDetailViewModel) so they can
    // reuse the same path/key resolution without duplicating it.
    nonisolated static func todayInterval() -> DateInterval {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? Date().addingTimeInterval(86_400)
        return DateInterval(start: start, end: end)
    }

    nonisolated static func defaultConfig() -> DatabaseConfig {
        #if LEAF_PROD
        return ProdConfigs.database
        #else
        return .weakDefaults
        #endif
    }

    nonisolated static func defaultEncryption() -> EncryptionOptions? {
        #if LEAF_PROD
        return EncryptionOptions(
            keyProvider: .callback { @Sendable in
                try FileKeyStore.fetchOrCreate()
            },
            preKeyPragmas: ProdConfigs.sqlcipherPragmasPreKey,
            postKeyPragmas: ProdConfigs.sqlcipherPragmasPostKey
        )
        #else
        return nil
        #endif
    }

    nonisolated private static func defaultDeepSessionMinSec() -> TimeInterval {
        #if LEAF_PROD
        return ProdConfigs.agent.deepSessionMinSec
        #else
        return AgentThresholds.weakDefaults.deepSessionMinSec
        #endif
    }
}
