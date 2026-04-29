import Foundation

/// View-model для popover (и любого другого consumer'а) — агрегированный
/// результат одного refresh-цикла Derived Insights Engine.
///
/// Phase 2.1 — три метрики (timeInApp + sessions + switchRate). Phase 2.2
/// расширен trends-полями (deepWorkStreak / peakHour / wow / activeDaysInRow).
/// Phase 2.3 — `aiRatio`. Trend-поля добавляются с semantic zero defaults
/// в convenience init'е — не ломает existing test callsite'ы.
///
/// Snapshot consider'ится empty если ВСЕ 7 текущих метрик пусты/zero/nil.
/// Partial-empty (есть topApps, нет sessions, нет trends) — `.loaded` с
/// placeholder в соответствующем UI-блоке.
public struct InsightsSnapshot: Sendable, Hashable {
    public let topApps: [AppTimeEntry]
    public let sessions: [FocusSession]
    /// Switches per active hour. `0.0` если active hours == 0.
    public let switchRate: Double
    /// Precomputed: count of sessions с `duration >= deepSessionMinSec`.
    /// Делается на producer-side чтобы UI не таскал threshold.
    public let deepSessionsCount: Int
    /// Phase 2.2 — consecutive days с deep session + cumulative deep time.
    /// `DeepWorkStreak.empty` == семантический "нет streak'а".
    public let deepWorkStreak: DeepWorkStreak
    /// Phase 2.2 — hour-of-day (0..23) наибольшей attention'а в trailing
    /// `peakHourWindowDays`. `nil` = данных меньше `peakHourMinActiveDays`.
    public let peakProductivityHour: Int?
    /// Phase 2.2 — signed fractional change attention time (`+0.12` = +12%).
    /// `nil` = baseline insufficient (prev week empty или `< wowBaselineMinActiveDays`).
    public let weekOverWeekDelta: Double?
    /// Phase 2.2 — consecutive active days ending at today/yesterday.
    /// `0` = сегодня не active и yesterday не active.
    public let activeDaysInRow: Int
    /// Phase 2.3 — per-minute bucket union ratio aiCollab/(ai∪attention).
    /// `0` = либо нет AI events, либо нет ни одной активной минуты в окне.
    public let aiRatio: Double
    /// Phase 2.3 — distinct minutes с AI activity × 60. UI показывает рядом с %.
    public let aiActiveSeconds: TimeInterval
    /// Phase 2.4 — top-N file paths за `period` (recency-ordered, MAX 10).
    /// Содержит уже granularity-mapped paths (router'ом on write — L4 даёт
    /// folder-level, L5 — full path). UI показывает basename + tooltip.
    public let filesTouched: [String]
    /// Phase 4.2 — distinct Linear issue keys touched за `period`.
    public let linearIssuesTouched: Int
    /// Phase 4.2 — top-5 projects by issue count, descending.
    public let linearByProject: [ProjectCountEntry]
    /// Phase 4.2 — top-5 statuses by issue count, descending.
    public let linearByStatus: [StatusCountEntry]
    /// Phase 4.3 — total GitHub events за `period` (commits / PRs / issues / reviews).
    public let githubEventsCount: Int
    /// Phase 4.3 — top-5 repos by event count, descending.
    public let githubByRepo: [RepoCountEntry]
    /// Phase 4.3 — top-5 event_kinds by count, descending.
    public let githubByEventKind: [EventKindCountEntry]
    /// Phase 4.4 — total Slack messages authored за `period` (sum of per-channel counts).
    public let slackMessagesCount: Int
    /// Phase 4.4 — total minutes юзер провёл в huddle'е за `period`, walk'ом
    /// huddle_state_change context events с clipping к границам periodа.
    public let slackHuddleMinutes: Int
    /// Phase 4.4 — top-5 channels by message count, descending. DM channels уже
    /// merged'ы в один "DM" bucket (ADR-010 anonymization).
    public let slackByChannel: [SlackActivityBreakdown.ChannelCountEntry]

    public init(
        topApps: [AppTimeEntry],
        sessions: [FocusSession],
        switchRate: Double,
        deepSessionsCount: Int,
        deepWorkStreak: DeepWorkStreak,
        peakProductivityHour: Int?,
        weekOverWeekDelta: Double?,
        activeDaysInRow: Int,
        aiRatio: Double,
        aiActiveSeconds: TimeInterval,
        filesTouched: [String],
        linearIssuesTouched: Int,
        linearByProject: [ProjectCountEntry],
        linearByStatus: [StatusCountEntry],
        githubEventsCount: Int,
        githubByRepo: [RepoCountEntry],
        githubByEventKind: [EventKindCountEntry],
        slackMessagesCount: Int,
        slackHuddleMinutes: Int,
        slackByChannel: [SlackActivityBreakdown.ChannelCountEntry]
    ) {
        self.topApps = topApps
        self.sessions = sessions
        self.switchRate = switchRate
        self.deepSessionsCount = deepSessionsCount
        self.deepWorkStreak = deepWorkStreak
        self.peakProductivityHour = peakProductivityHour
        self.weekOverWeekDelta = weekOverWeekDelta
        self.activeDaysInRow = activeDaysInRow
        self.aiRatio = aiRatio
        self.aiActiveSeconds = aiActiveSeconds
        self.filesTouched = filesTouched
        self.linearIssuesTouched = linearIssuesTouched
        self.linearByProject = linearByProject
        self.linearByStatus = linearByStatus
        self.githubEventsCount = githubEventsCount
        self.githubByRepo = githubByRepo
        self.githubByEventKind = githubByEventKind
        self.slackMessagesCount = slackMessagesCount
        self.slackHuddleMinutes = slackHuddleMinutes
        self.slackByChannel = slackByChannel
    }

    /// Convenience init — рассчитывает `deepSessionsCount` по threshold'у.
    /// Phase 2.2 — trend-поля с default'ами; Phase 2.3 — AI-поля с default'ами;
    /// Phase 2.4 — `filesTouched` с default `[]`. Phase 4.2 — Linear-поля с defaults.
    /// Phase 4.3 — GitHub-поля с defaults. Phase 4.4 — Slack-поля с defaults.
    /// Existing test/UI callsite'ы не ломаются.
    public init(
        topApps: [AppTimeEntry],
        sessions: [FocusSession],
        switchRate: Double,
        deepSessionMinSec: TimeInterval,
        deepWorkStreak: DeepWorkStreak = .empty,
        peakProductivityHour: Int? = nil,
        weekOverWeekDelta: Double? = nil,
        activeDaysInRow: Int = 0,
        aiRatio: Double = 0,
        aiActiveSeconds: TimeInterval = 0,
        filesTouched: [String] = [],
        linearIssuesTouched: Int = 0,
        linearByProject: [ProjectCountEntry] = [],
        linearByStatus: [StatusCountEntry] = [],
        githubEventsCount: Int = 0,
        githubByRepo: [RepoCountEntry] = [],
        githubByEventKind: [EventKindCountEntry] = [],
        slackMessagesCount: Int = 0,
        slackHuddleMinutes: Int = 0,
        slackByChannel: [SlackActivityBreakdown.ChannelCountEntry] = []
    ) {
        self.init(
            topApps: topApps,
            sessions: sessions,
            switchRate: switchRate,
            deepSessionsCount: sessions.filter { $0.duration >= deepSessionMinSec }.count,
            deepWorkStreak: deepWorkStreak,
            peakProductivityHour: peakProductivityHour,
            weekOverWeekDelta: weekOverWeekDelta,
            activeDaysInRow: activeDaysInRow,
            aiRatio: aiRatio,
            aiActiveSeconds: aiActiveSeconds,
            filesTouched: filesTouched,
            linearIssuesTouched: linearIssuesTouched,
            linearByProject: linearByProject,
            linearByStatus: linearByStatus,
            githubEventsCount: githubEventsCount,
            githubByRepo: githubByRepo,
            githubByEventKind: githubByEventKind,
            slackMessagesCount: slackMessagesCount,
            slackHuddleMinutes: slackHuddleMinutes,
            slackByChannel: slackByChannel
        )
    }

    public var isEmpty: Bool {
        topApps.isEmpty
            && sessions.isEmpty
            && switchRate == 0
            && deepWorkStreak.days == 0
            && peakProductivityHour == nil
            && weekOverWeekDelta == nil
            && activeDaysInRow == 0
            && aiRatio == 0
            && aiActiveSeconds == 0
            && filesTouched.isEmpty
            && linearIssuesTouched == 0
            && githubEventsCount == 0
            && slackMessagesCount == 0
            && slackHuddleMinutes == 0
    }

    /// Average session duration. `0` если sessions пуст.
    public var avgSessionDuration: TimeInterval {
        guard !sessions.isEmpty else { return 0 }
        return sessions.reduce(0.0) { $0 + $1.duration } / Double(sessions.count)
    }
}
