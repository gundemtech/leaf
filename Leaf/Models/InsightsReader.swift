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
import Observation
import OSLog
import LeafCore
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
    /// Wall-clock time of the last *successful* refresh completion (`.loaded`
    /// or `.empty`). Drives the staleness window — see `refresh(force:)`.
    /// nil until the first successful load; never set on `.error` /
    /// `.notConfigured` so those stay retryable on the next ambient hop (M-XI).
    private var lastRefreshedAt: Date?
    /// Track-10 T5 — UserDefaults-backed cursor for SINCE YOU WERE LAST ACTIVE.
    /// Set via `configure(lastSeenCursor:)` from `LeafApp` at app launch;
    /// `nil` before configure → `sinceLastActiveItems` returns `[]` from refresh().
    private var lastSeenCursor: LastSeenCursor?
    /// Track-10 T6 (Phase IV.B) — active-workspace store for the Zone-3
    /// solo-vs-team gate. Set via `configure(activeWorkspaceStore:)` from
    /// `LeafApp` at launch; `nil` before configure → `memberCount` falls back
    /// to 1 (solo-safe). @MainActor-isolated, so its id is snapshotted on the
    /// MainActor before the detached read (mirrors the `lastSeenCursor` hop).
    private var activeWorkspaceStore: ActiveWorkspaceStore?
    /// Track-9 T6 (C-2) — last successful snapshot, updated on every `.loaded`
    /// transition. Read by error path to populate `State.error.lastKnown`.
    /// Instance field (not local) so overlapping refreshes (rapid double-tap on
    /// "Refresh") don't lose the snapshot when call #2 sees `state == .loading`
    /// set by call #1.
    private var lastKnownSnapshot: InsightsSnapshot?

    private let databaseURL: URL
    private let databaseConfig: DatabaseConfig
    private let databaseEncryption: EncryptionOptions?
    /// Threshold "deep" — берётся из ProdConfigs (LEAF_PROD) или weakDefaults.
    /// Применяется на producer-side при сборке snapshot, UI не пересчитывает.
    private let deepSessionMinSec: TimeInterval
    /// Ambient refreshes within this window of the last successful load are
    /// skipped (tab-switch storm guard, M-XI). Injectable for tests/tuning.
    private let freshnessWindow: TimeInterval
    /// Injectable now() — tests drive it deterministically; prod uses Date().
    private let clock: @Sendable () -> Date
    private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "insights")

    init(
        databaseURL: URL = DatabasePath.defaultURL(),
        databaseConfig: DatabaseConfig = InsightsReader.defaultConfig(),
        databaseEncryption: EncryptionOptions? = InsightsReader.defaultEncryption(),
        deepSessionMinSec: TimeInterval = InsightsReader.defaultDeepSessionMinSec(),
        freshnessWindow: TimeInterval = 5,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.databaseURL = databaseURL
        self.databaseConfig = databaseConfig
        self.databaseEncryption = databaseEncryption
        self.deepSessionMinSec = deepSessionMinSec
        self.freshnessWindow = freshnessWindow
        self.clock = clock
    }

    /// Track-10 T5 — two-phase configure pattern. `LeafApp` calls this once at
    /// app launch (`.task` modifier on root view) to wire the @Observable
    /// cursor into the reader. Triggers an explicit refresh so the snapshot
    /// populates `sinceLastActiveItems` on the first appearance.
    func configure(lastSeenCursor: LastSeenCursor) {
        self.lastSeenCursor = lastSeenCursor
        refresh(force: true)
    }

    /// Track-10 T6 (Phase IV.B) — inject the active-workspace store for the
    /// solo-vs-team gate. Field-only set (no refresh) — call this BEFORE
    /// `configure(lastSeenCursor:)` so the single launch refresh that the
    /// cursor configure triggers already sees the store. Idempotent.
    func configure(activeWorkspaceStore: ActiveWorkspaceStore) {
        self.activeWorkspaceStore = activeWorkspaceStore
    }

    func refresh(force: Bool = false) {
        // Staleness window — skip redundant SQL when a successful load landed
        // less than `freshnessWindow` ago (rapid ambient tab-switch storm,
        // M-XI). Explicit user-initiated refreshes pass force:true and always
        // proceed. Gated before cancel/file-check so a fresh state is a pure
        // no-op; errors are never stamped, so they stay retryable here.
        if !force, RefreshFreshness.isFresh(lastRefreshedAt: lastRefreshedAt, now: clock(), window: freshnessWindow) {
            return
        }
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
        // Track-10 T5 — snapshot cursor on MainActor BEFORE the detached task so
        // the SQL call has a plain Int64 to work with (LastSeenCursor is
        // @MainActor-isolated). `nil` cursor → skip the feed call entirely.
        let cursorMs: Int64? = lastSeenCursor?.lastSeenAtMs
        // Track-10 T6 (Phase IV.B) — snapshot the active workspace id on the
        // MainActor before the detached task (ActiveWorkspaceStore is
        // @MainActor-isolated). `nil` → memberCount falls back to 1 (solo-safe)
        // in the detached read below.
        let activeWorkspaceID: String? = activeWorkspaceStore?.activeWorkspaceID

        currentTask = Task { [self] in
            // Database (@unchecked Sendable) и InsightsSnapshot (Sendable) —
            // hopping через MainActor.run после background compute race-safe.
            let result: Result<(LeafCore.Database, InsightsSnapshot), Error> =
                await Task.detached(priority: .userInitiated) {
                    do {
                        let db = try cachedDB ?? LeafCore.Database.openForRead(at: url, config: cfg, encryption: enc)
                        let insights = DerivedInsightsFactory.make(database: db)
                        let today = InsightsReader.todayInterval()
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
                        // Track-10 T6 — broader presence pulse. Reader returns []
                        // today; Phase 5.4 wires DBTeammatePresenceReader against
                        // presence_history. 15-min maxAge matches master spec §3.4.
                        let teammateReader = TeammatePresenceReaderFactory.make(database: db)
                        let activeTeammates = try teammateReader
                            .recentTeammateSnapshots(maxAge: 15 * 60, now: Date())
                        try Task.checkCancellation()
                        // Track-10 T6 — solo-vs-team gate for HomeView Zone-3.
                        // Active-workspace member count from the `team_members`
                        // table (the same `readTeamMembers` call WorkspaceReader's
                        // loader uses). Fallback to 1 (solo-safe) on a nil active
                        // workspace id or any DB read failure — Home rendering must
                        // never block on a workspace-membership query. The TEAM·N
                        // gate fires only at ≥2 active members; the teammates list
                        // itself stays stub-empty until Phase 5.4 wires presence.
                        let memberCount: Int
                        if let activeWorkspaceID {
                            do {
                                memberCount = try db.readTeamMembers(
                                    workspaceID: activeWorkspaceID,
                                    includeRemoved: false
                                ).count
                            } catch {
                                // Solo-safe fallback — never block Home on a
                                // membership read. Logged (not swallowed) so a
                                // real schema/decrypt fault is diagnosable rather
                                // than silently degrading a team install to solo
                                // UI. Logger created inline: the instance `logger`
                                // is @MainActor-isolated, unreachable from this
                                // detached task (os.Logger is Sendable + cheap).
                                Logger(subsystem: "tech.gundem.leaf.app", category: "insights")
                                    .error("memberCount readTeamMembers failed: \(String(describing: error), privacy: .public)")
                                memberCount = 1
                            }
                        } else {
                            memberCount = 1
                        }
                        try Task.checkCancellation()
                        // Track-8 Phase 8.6 — INBOX dashboard items list.
                        // Fetched with .all/"" defaults; filter + search
                        // applied view-side as @State, no re-fetch on
                        // keystroke. Stub returns [] until Phase 4.8/4.9
                        // wire Layer B; D3 detection tables already feed
                        // open questions + blockers via the moat impl.
                        let inboxItems = try insights.inboxItems(filter: .all, query: "")
                        try Task.checkCancellation()
                        // Track-8 Phase 8.7 + Track-9 T7 — WHERE STOPPED snapshot
                        // with Path B composition. Reader fetches the most
                        // recent stop-point row (substrate returns most-recent-
                        // first), then splices `recentLastCommit` from the
                        // Track-9 T1 deriver. nil base → no commit composition.
                        // IV.A.1 — recentWhereStopped(limit:) protocol method not on
                        // integration DerivedInsights yet; stub nil. IV.A.2 will add
                        // the method (or wire to alternate source). ResumeHeroBlock
                        // handles nil whereStopped via blank-shell fence (T2.5).
                        let whereStoppedBase: WhereStoppedSnapshot? = nil
                        try Task.checkCancellation()
                        // Track-9 T7 — 4h cutoff per spec §9 call C.
                        let recentLastCommit = try insights.recentLastCommit(
                            maxAgeMs: 4 * 60 * 60 * 1000
                        )
                        try Task.checkCancellation()
                        // Track-9 T9 — Analytics weekly metrics (7-day window
                        // anchored at local-TZ midnight). Pure read; T4 ships
                        // ProdInsights+WeeklyMetrics with 5 streaks + WoW.
                        let weeklyMetrics = try insights.weeklyMetrics(now: Date())
                        try Task.checkCancellation()
                        // Track-10 T2 — task identity (linearID / branch / repo /
                        // linearWorkspaceSlug) for RESUME hero CTAs. workspacePath
                        // intentionally NOT carried on the struct (T5 D-8) — see
                        // currentWorkspacePath() below for the ephemeral fetch.
                        let taskIdentity = try insights.currentTaskIdentity()
                        try Task.checkCancellation()
                        // Track-10 T2 — ephemeral workspace path → in-process git
                        // delta read (ahead/behind/uncommitted + parsed remote).
                        // Path bytes stay scoped to this `await`; only counts +
                        // structured ref strings + parsed remote propagate into the
                        // snapshot. Stub fallback (non-LEAF_PROD) returns nil.
                        let workspacePath = try insights.currentWorkspacePath()
                        try Task.checkCancellation()
                        let gitDelta = await GitDeltaReaderFactory.make()
                            .read(forWorkspacePath: workspacePath)
                        try Task.checkCancellation()
                        // Track-10 T7 — bundled task-session lens (LEAF-ID +
                        // branch + commits ahead + session start + per-task
                        // focused-min + recent open files) for the Home YOU'RE ON
                        // block. Composed via per-IDE dispatch (Xcode doc_path
                        // walk + VSCode/JetBrains workspace_root match) +
                        // attention dwell SUM + basename-only openFiles cap 3.
                        // Stays nil for empty fixtures and Terminal-only work
                        // where currentTaskIdentity() can't resolve.
                        let currentSession = try insights.currentTaskSession()
                        try Task.checkCancellation()
                        // Track-10 T8 — RECAP + EOD standup composition. Zero
                        // new substrate: reuses recentActivityFeed (T5) twice
                        // (yesterday + today windows) plus todayMetrics
                        // (Phase 8.3) once more for yesterday's commits-per-day.
                        //
                        // DST behavior: dateInterval(of: .day, for:) returns a
                        // 23h interval on spring-forward days and 25h on
                        // fall-back days; since recentActivityFeed works on
                        // epoch ms the only effect is a slightly trimmed/
                        // extended window — not a defect.
                        //
                        // F-CTO-T8-L — Calendar.date(byAdding:to:) returns
                        // Optional; fallback to addingTimeInterval(-86_400) so
                        // yesterdayStart is never == now (which would silently
                        // collapse RECAP into a duplicate of today).
                        let now = Date()
                        let cal = Calendar.current
                        let yesterdayStart = cal.date(byAdding: .day, value: -1, to: now)
                            ?? now.addingTimeInterval(-86_400)
                        let yesterdayInterval = cal.dateInterval(of: .day, for: yesterdayStart)
                            ?? DateInterval(start: yesterdayStart, duration: 86_400)
                        let todayInterval = cal.dateInterval(of: .day, for: now)
                            ?? DateInterval(start: cal.startOfDay(for: now), duration: 86_400)
                        let yesterdayMs = Int64(yesterdayInterval.start.timeIntervalSince1970 * 1000)
                        let todayMs = Int64(todayInterval.start.timeIntervalSince1970 * 1000)
                        let standupYesterdayFeed =
                            (try? insights.recentActivityFeed(since: yesterdayMs, limit: 100)) ?? []
                        try Task.checkCancellation()
                        let standupTodayFeed =
                            (try? insights.recentActivityFeed(since: todayMs, limit: 100)) ?? []
                        try Task.checkCancellation()
                        let yesterdayMetrics =
                            (try? insights.todayMetrics(now: yesterdayStart)) ?? .empty
                        try Task.checkCancellation()
                        let standupBlockers = (try? insights.openBlockers()) ?? []
                        try Task.checkCancellation()
                        let standupSnapshot = StandupComposer.compose(
                            yesterdayActivity: standupYesterdayFeed,
                            todayActivity: standupTodayFeed,
                            yesterdayMetrics: yesterdayMetrics,
                            todayMetrics: todayMetrics,
                            actionableItems: inboxItems,
                            openBlockers: standupBlockers,
                            currentTask: taskIdentity,
                            latestStop: whereStoppedBase,
                            now: now
                        )
                        try Task.checkCancellation()
                        // Track-10 T5 — per-event SINCE timeline. `cursorMs == nil`
                        // before LeafApp's `configure(lastSeenCursor:)` lands;
                        // emit `[]` so the snapshot composition stays stable
                        // (snapshot eq-Hash invariant preserved — same input
                        // produces same output across refresh ticks).
                        let sinceLastActiveItems: [SinceLastActiveItem]
                        if let cursorMs {
                            let feed = (try? insights.recentActivityFeed(
                                since: cursorMs, limit: 100)) ?? []
                            sinceLastActiveItems = feed.compactMap(SinceLastActiveItem.compose(from:))
                        } else {
                            sinceLastActiveItems = []
                        }
                        try Task.checkCancellation()
                        // Path B — splice commit into deriver's snapshot via
                        // defaulted-init. Preserves anchorFilePath / anchorLine
                        // populated by ProdInsights+RecentWhereStopped LEFT JOIN.
                        // Track-10 T2 — also preserves anchorBundleID from same row.
                        let whereStopped: WhereStoppedSnapshot? = whereStoppedBase.map { base in
                            WhereStoppedSnapshot(
                                id: base.id,
                                generatedAtMs: base.generatedAtMs,
                                anchorEventId: base.anchorEventId,
                                excerpt: base.excerpt,
                                wipSignals: base.wipSignals,
                                anchorFilePath: base.anchorFilePath,
                                anchorLine: base.anchorLine,
                                recentLastCommit: recentLastCommit,
                                anchorBundleID: base.anchorBundleID
                            )
                        }
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
                            presenceState: presenceState,
                            recentSessions: recentSessions,
                            todayMetrics: todayMetrics,
                            youNowState: youNowState,
                            inboxItems: inboxItems,
                            whereStopped: whereStopped,
                            weeklyMetrics: weeklyMetrics,
                            gitDelta: gitDelta,
                            currentTaskIdentity: taskIdentity,
                            sinceLastActiveItems: sinceLastActiveItems,
                            activeTeammates: activeTeammates,
                            memberCount: memberCount,
                            currentSession: currentSession,
                            standupRecap: standupSnapshot
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
                // Stamp on any successful query completion (data or not) so the
                // staleness window throttles subsequent ambient refreshes. Set
                // before mutating state; both .empty and .loaded count as fresh.
                self.lastRefreshedAt = self.clock()
                if snapshot.isEmpty {
                    self.state = .empty(
                        message: "Collecting… activity will appear after a few app switches."
                    )
                } else {
                    // IV.A.1 — lastKnownSnapshot field not added (T6.3 review fix skipped)
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

    nonisolated private static func todayInterval() -> DateInterval {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? Date().addingTimeInterval(86_400)
        return DateInterval(start: start, end: end)
    }

    nonisolated private static func defaultConfig() -> DatabaseConfig {
        #if LEAF_PROD
        return ProdConfigs.database
        #else
        return .weakDefaults
        #endif
    }

    nonisolated private static func defaultEncryption() -> EncryptionOptions? {
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
