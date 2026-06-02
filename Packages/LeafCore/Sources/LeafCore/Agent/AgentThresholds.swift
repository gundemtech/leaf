import Foundation

/// Tunables for the Agent runtime. Production values are moat (`LeafCorePrivate/Prod/Configs/AgentThresholdsProd.swift`).
/// `weakDefaults` — generic defaults for CI and dev builds without moat.
public struct AgentThresholds: Sendable, Hashable {
    /// How often to check CGEventSource idle.
    public let idlePollIntervalSec: TimeInterval
    /// How many seconds without input counts as idle → we write context `{state: "idle"}`.
    public let idleThresholdSec: TimeInterval
    /// How often EventWriter flushes its buffer to the DB.
    public let eventFlushIntervalSec: TimeInterval
    /// Once the buffer reaches this size it flushes immediately (no waiting for the interval).
    public let eventFlushBatchSize: Int
    /// How often MaintenanceScheduler runs the retention sweep (DELETE of old events).
    public let retentionSweepIntervalSec: TimeInterval
    /// Cutoff: events with `ts < now - retentionDays * 86400s` are removed by the sweep.
    public let retentionDays: Int
    /// Phase 2.1: gap between two consecutive attention events after which a
    /// session is considered finished. Default `idleThresholdSec * 2` —
    /// "two missed idle-checkpoints = session ended".
    public let focusSessionGapSec: TimeInterval
    /// Phase 2.1: minimum session duration to count as "deep".
    /// Default 1500s = 25min (Pomodoro lower bound).
    public let deepSessionMinSec: TimeInterval
    /// Phase 2.5: minimum seconds in a new app to count a context switch.
    /// A quick alt-tab peek (a Telegram check for <N sec) should not inflate
    /// switches/h. Applied in the `contextSwitchRate` SQL via a LEAD(ts) check.
    /// `weakDefault = 0` → no filter (back-compat for tests); prod value
    /// is in moat. Does not affect `focusSessions` segmentation — only the switch counter.
    public let contextSwitchMinHoldSec: TimeInterval
    /// Phase 2.2: minimum attention-seconds per day for a day to count as "active"
    /// in `activeDaysInRow`. Default 1800s = 30min.
    public let activeDayMinAttentionSec: TimeInterval
    /// Phase 2.2: aggregation window for `peakProductivityHour` — trailing N days.
    public let peakHourWindowDays: Int
    /// Phase 2.2: minimum active days in the window for `peakProductivityHour`
    /// not to return nil. Below → insufficient data.
    public let peakHourMinActiveDays: Int
    /// Phase 2.2: minimum active days in the previous-week window for
    /// `weekOverWeekDelta` not to return nil.
    public let wowBaselineMinActiveDays: Int
    /// Phase 2.3: how often `ClaudeCodeCollector` scans `~/.claude/projects/`
    /// and tail-reads .jsonl. Real prod 90s in moat; weakDefault — 120s.
    public let aiCollectIntervalSec: TimeInterval
    /// Phase 2.3: window of "recent" jsonl files to backfill on first launch.
    /// `mtime >= now - backfillWindowDays * 86400s` → read from byte_offset=0
    /// (a historical slice lands in the DB). Otherwise skip-backward (offset = file size).
    public let backfillWindowDays: Int
    /// Phase 2.3: path to the Claude Code projects root. Supports a leading `~`
    /// (expanded callsite-side via `NSString.expandingTildeInPath`).
    public let claudeCodeProjectsPath: String
    /// Phase 2.4: FSEvents stream `latency` (CFTimeInterval) — the OS coalescing
    /// window before a batch is delivered to the callback. Real prod ~0.5s in moat.
    public let fsEventsLatencySec: TimeInterval
    /// Phase 2.4: poll fallback interval for `FSEventsCollector.reload()` —
    /// belt+suspenders in case a Darwin notification is lost.
    public let fsEventsReconfigPollSec: TimeInterval
    /// Phase 2.4: name of the `DistributedNotificationCenter` notification by which
    /// the UI signals the Agent that watched_folders changed → reload.
    public let fsEventsRestartTriggerName: String
    /// Phase 2.4: coalesce dedup window — same `(path, kind)` within this window → drop.
    /// Applied only in the Prod router (moat). The stub coalesce ignores it.
    /// `weakDefault = 0` → effectively no coalesce; the exact prod value is in moat.
    public let fsEventsCoalesceWindowSec: TimeInterval
    /// Phase 4.2: how often `LinearCollector` polls Linear GraphQL.
    /// Whitepaper: 5 min = 300s (≈ 75 complexity pts/call, 900/hr under the 2M/hr limit).
    /// `weakDefault = 300` (CI / dev — but the collector skips startup if clientID is empty).
    public let linearPollIntervalSec: TimeInterval
    /// Phase 4.2: Linear OAuth public client_id. Already committed in `Production.xcconfig`,
    /// public by the nature of OAuth. Threaded into the Agent process via AgentThresholds
    /// (not Info.plist, since the tool target has no INFOPLIST_FILE). Empty string → collector
    /// graceful no-op (does not start).
    public let linearOAuthClientID: String
    /// Phase 4.3: how often `GitHubCollector` polls the REST events feed.
    /// Whitepaper: 5 min = 300s — well below 5000/hr REST primary rate-limit.
    public let githubPollIntervalSec: TimeInterval
    /// Phase 4.3: GitHub OAuth public client_id (Device Flow). Same model
    /// as Linear — committed in `Production.xcconfig`, hardcoded in the moat copy
    /// for the Agent target (no INFOPLIST_FILE). Empty string → collector skip.
    public let githubOAuthClientID: String
    /// Phase 4.4: how often `SlackCollector` polls REST endpoints
    /// (`users.profile.get` + `search.messages`). 5min = 300s — 24 calls/hr,
    /// 1000× headroom against Tier 2+ rate-limits.
    public let slackPollIntervalSec: TimeInterval
    /// Phase 4.4: Slack OAuth public client_id (PKCE loopback). Same model
    /// as Linear/GitHub — committed in `Production.xcconfig`, hardcoded in the moat copy
    /// for the Agent target (no INFOPLIST_FILE). Empty string → collector skip.
    public let slackOAuthClientID: String
    /// Phase Track-3 D1 — interval (seconds) for LinearWarmCollector 15m tier.
    public let linearWarmPollIntervalSec: TimeInterval
    /// Phase Track-3 D1 — interval (seconds) for LinearColdCollector. Not used
    /// directly by the scheduler (4am local anchor instead) — retained for
    /// symmetry and potential debug overrides.
    public let linearColdPollIntervalSec: TimeInterval
    /// Phase Track-3 D2 — interval (seconds) for GitHubWarmCollector 15m tier.
    /// Mirrors `linearWarmPollIntervalSec` (default 900s).
    public let githubWarmPollIntervalSec: TimeInterval
    /// Phase Track-3 D2 — interval (seconds) for GitHubColdCollector. Not used
    /// directly by the scheduler (4am local anchor instead) — retained for
    /// symmetry and potential debug overrides. Mirrors Linear D1 precedent.
    public let githubColdPollIntervalSec: TimeInterval
    /// Phase Track-3 D3 — interval (seconds) for SlackWarmCollector 15m tier.
    /// Mirrors `githubWarmPollIntervalSec` (default 900s).
    public let slackWarmPollIntervalSec: TimeInterval
    /// Phase Track-3 D3 — interval (seconds) for SlackColdCollector. Not used
    /// directly by the scheduler (4am local anchor instead) — retained for
    /// symmetry and potential debug overrides.
    public let slackColdPollIntervalSec: TimeInterval
    /// Phase 4.10.B: how often `ActiveAppCollector` polls the frontmost app +
    /// window title for in-app window-change detection (separate from the NSWorkspace
    /// activation observer — that one catches only app switches). Diff suppression
    /// in `AttentionEmissionPlanner` guarantees that identical (bundle, title)
    /// polls do not write redundant events.
    public let attentionWindowPollIntervalSec: TimeInterval
    /// Phase 5.3.E: how often `RotationFetchScheduler` polls relay's
    /// `/v1/key-rotation/by-peer/*` mailbox + opportunistically resumes admin-side
    /// `rotation_outbox`. Default 60s — consistent with presence WS heartbeat in 5.4
    /// contract; member-removal latency feels live-team.
    public let rotationFetchIntervalSec: TimeInterval
    /// Phase Track-1 D3: how often `DetectorPipeline.runIncremental` runs against
    /// newly-flushed events. The cursor model in `detector_offsets` is incremental
    /// + idempotent (per-event INSERT OR IGNORE), so a periodic timer is functionally
    /// equivalent to a strict per-flush hook with at most one timer-period of detection
    /// latency. Decoupled from collectors keeps moat boundary clean (no collector-side
    /// dependency on detector layer). Default 30s — fast enough for "show within next
    /// MCP tool call" UX while leaving ample headroom under heaviest write tick.
    public let detectorIncrementalIntervalSec: TimeInterval
    /// Phase Track-1 D3: how often `DetectorPipeline.runScheduled` runs against the
    /// LinearStuck scanner + WhereStoppedDeriver. Independent from incremental cadence
    /// because (a) these scanners read AGGREGATE state (not per-event) so don't need
    /// per-event freshness, and (b) `WhereStoppedDeriver.idleSeconds` is the natural
    /// floor — running more often just produces nil outputs. Default 300s mirrors the
    /// prod `idleThresholdSec` ceiling; production override in moat.
    public let detectorScheduledIntervalSec: TimeInterval
    /// Phase Track-4 S1: how often `CalendarCollector` polls `EKEventStore` for
    /// overlap with the current moment. Default 60s.
    public let calendarPollIntervalSec: TimeInterval
    /// Phase Track-4 S1: how often `FocusModeCollector` polls
    /// `INFocusStatusCenter.default.focusStatus`. Default 60s — mirrors
    /// `calendarPollIntervalSec`.
    public let focusModePollIntervalSec: TimeInterval
    /// Phase Track-4 S1: drop space-switched emissions within this many seconds
    /// of the prior emission (collapses rapid Mission-Control gesture sweeps).
    /// Default 2s.
    public let spaceTransitionCoalesceWindowSec: TimeInterval
    /// Phase Track-4 S2: default per-adapter AppleScript timeout in seconds.
    /// Adapters can override (Zoom uses 3.0s) via
    /// `appleScriptPerAppTimeoutOverridesJson`.
    public let appleScriptDefaultTimeoutSec: Double
    /// Phase Track-4 S2: JSON dict of bundleID → seconds, parsed in moat.
    /// Default `{"us.zoom.xos":3.0}`.
    public let appleScriptPerAppTimeoutOverridesJson: String

    /// Phase Track-4 S3: CGEventTapCollector minute-boundary flush + emit cadence.
    /// Default 60s — wall-clock minute alignment for `intensity_aggregates` PK.
    public let cgEventTapMinuteBucketSec: TimeInterval
    /// Phase Track-4 S3: NSPasteboard.changeCount delta polling cadence.
    /// Default 60s.
    public let clipboardPollIntervalSec: TimeInterval
    /// Phase Track-4 S3: CWInterface state polling cadence.
    /// Default 60s.
    public let wifiPollIntervalSec: TimeInterval
    /// Phase Track-4 S3: FSEvents burst dedup window for LocalFilesWatcher
    /// (screenshot/downloads/trash). Default 2s — mirrors S1 spaceTransitionCoalesce.
    public let localFilesCoalesceWindowSec: TimeInterval
    /// Phase Track-4 S3: testing override for the screenshot directory. Empty =
    /// read from `com.apple.screencapture` defaults / fallback `~/Desktop`.
    /// Non-empty = absolute path (for test fixtures).
    public let screenshotDirectoryOverridePath: String

    public init(
        idlePollIntervalSec: TimeInterval,
        idleThresholdSec: TimeInterval,
        eventFlushIntervalSec: TimeInterval,
        eventFlushBatchSize: Int,
        retentionSweepIntervalSec: TimeInterval,
        retentionDays: Int,
        focusSessionGapSec: TimeInterval,
        deepSessionMinSec: TimeInterval,
        contextSwitchMinHoldSec: TimeInterval = 0,
        activeDayMinAttentionSec: TimeInterval,
        peakHourWindowDays: Int,
        peakHourMinActiveDays: Int,
        wowBaselineMinActiveDays: Int,
        aiCollectIntervalSec: TimeInterval,
        backfillWindowDays: Int,
        claudeCodeProjectsPath: String,
        fsEventsLatencySec: TimeInterval = 0.5,
        fsEventsReconfigPollSec: TimeInterval = 60,
        fsEventsRestartTriggerName: String = "tech.gundem.leaf.watched-folders-changed",
        fsEventsCoalesceWindowSec: TimeInterval = 0,
        linearPollIntervalSec: TimeInterval = 300,
        linearOAuthClientID: String = "",
        githubPollIntervalSec: TimeInterval = 300,
        githubOAuthClientID: String = "",
        slackPollIntervalSec: TimeInterval = 300,
        slackOAuthClientID: String = "",
        linearWarmPollIntervalSec: TimeInterval = 900,
        linearColdPollIntervalSec: TimeInterval = 86_400,
        githubWarmPollIntervalSec: TimeInterval = 900,
        githubColdPollIntervalSec: TimeInterval = 86_400,
        slackWarmPollIntervalSec: TimeInterval = 900,
        slackColdPollIntervalSec: TimeInterval = 86_400,
        attentionWindowPollIntervalSec: TimeInterval = 30,
        rotationFetchIntervalSec: TimeInterval = 60,
        detectorIncrementalIntervalSec: TimeInterval = 30,
        detectorScheduledIntervalSec: TimeInterval = 300,
        calendarPollIntervalSec: TimeInterval = 60,
        focusModePollIntervalSec: TimeInterval = 60,
        spaceTransitionCoalesceWindowSec: TimeInterval = 2,
        appleScriptDefaultTimeoutSec: Double = 1.0,
        appleScriptPerAppTimeoutOverridesJson: String = "{\"us.zoom.xos\":3.0}",
        cgEventTapMinuteBucketSec: TimeInterval = 60,
        clipboardPollIntervalSec: TimeInterval = 60,
        wifiPollIntervalSec: TimeInterval = 60,
        localFilesCoalesceWindowSec: TimeInterval = 2,
        screenshotDirectoryOverridePath: String = ""
    ) {
        self.idlePollIntervalSec = idlePollIntervalSec
        self.idleThresholdSec = idleThresholdSec
        self.eventFlushIntervalSec = eventFlushIntervalSec
        self.eventFlushBatchSize = eventFlushBatchSize
        self.retentionSweepIntervalSec = retentionSweepIntervalSec
        self.retentionDays = retentionDays
        self.focusSessionGapSec = focusSessionGapSec
        self.deepSessionMinSec = deepSessionMinSec
        self.contextSwitchMinHoldSec = contextSwitchMinHoldSec
        self.activeDayMinAttentionSec = activeDayMinAttentionSec
        self.peakHourWindowDays = peakHourWindowDays
        self.peakHourMinActiveDays = peakHourMinActiveDays
        self.wowBaselineMinActiveDays = wowBaselineMinActiveDays
        self.aiCollectIntervalSec = aiCollectIntervalSec
        self.backfillWindowDays = backfillWindowDays
        self.claudeCodeProjectsPath = claudeCodeProjectsPath
        self.fsEventsLatencySec = fsEventsLatencySec
        self.fsEventsReconfigPollSec = fsEventsReconfigPollSec
        self.fsEventsRestartTriggerName = fsEventsRestartTriggerName
        self.fsEventsCoalesceWindowSec = fsEventsCoalesceWindowSec
        self.linearPollIntervalSec = linearPollIntervalSec
        self.linearOAuthClientID = linearOAuthClientID
        self.githubPollIntervalSec = githubPollIntervalSec
        self.githubOAuthClientID = githubOAuthClientID
        self.slackPollIntervalSec = slackPollIntervalSec
        self.slackOAuthClientID = slackOAuthClientID
        self.linearWarmPollIntervalSec = linearWarmPollIntervalSec
        self.linearColdPollIntervalSec = linearColdPollIntervalSec
        self.githubWarmPollIntervalSec = githubWarmPollIntervalSec
        self.githubColdPollIntervalSec = githubColdPollIntervalSec
        self.slackWarmPollIntervalSec = slackWarmPollIntervalSec
        self.slackColdPollIntervalSec = slackColdPollIntervalSec
        self.attentionWindowPollIntervalSec = attentionWindowPollIntervalSec
        self.rotationFetchIntervalSec = rotationFetchIntervalSec
        self.detectorIncrementalIntervalSec = detectorIncrementalIntervalSec
        self.detectorScheduledIntervalSec = detectorScheduledIntervalSec
        self.calendarPollIntervalSec = calendarPollIntervalSec
        self.focusModePollIntervalSec = focusModePollIntervalSec
        self.spaceTransitionCoalesceWindowSec = spaceTransitionCoalesceWindowSec
        self.appleScriptDefaultTimeoutSec = appleScriptDefaultTimeoutSec
        self.appleScriptPerAppTimeoutOverridesJson = appleScriptPerAppTimeoutOverridesJson
        self.cgEventTapMinuteBucketSec = cgEventTapMinuteBucketSec
        self.clipboardPollIntervalSec = clipboardPollIntervalSec
        self.wifiPollIntervalSec = wifiPollIntervalSec
        self.localFilesCoalesceWindowSec = localFilesCoalesceWindowSec
        self.screenshotDirectoryOverridePath = screenshotDirectoryOverridePath
    }

    public static let weakDefaults = AgentThresholds(
        idlePollIntervalSec: 10,
        idleThresholdSec: 300,
        eventFlushIntervalSec: 5,
        eventFlushBatchSize: 50,
        retentionSweepIntervalSec: 86_400,
        retentionDays: 365,
        focusSessionGapSec: 600,
        deepSessionMinSec: 1500,
        contextSwitchMinHoldSec: 0,
        activeDayMinAttentionSec: 1800,
        peakHourWindowDays: 14,
        peakHourMinActiveDays: 7,
        wowBaselineMinActiveDays: 2,
        aiCollectIntervalSec: 120,
        backfillWindowDays: 7,
        claudeCodeProjectsPath: "~/.claude/projects",
        fsEventsLatencySec: 0.5,
        fsEventsReconfigPollSec: 60,
        fsEventsRestartTriggerName: "tech.gundem.leaf.watched-folders-changed",
        fsEventsCoalesceWindowSec: 0,
        linearPollIntervalSec: 300,
        linearOAuthClientID: "",
        githubPollIntervalSec: 300,
        githubOAuthClientID: "",
        slackPollIntervalSec: 300,
        slackOAuthClientID: "",
        linearWarmPollIntervalSec: 900,
        linearColdPollIntervalSec: 86_400,
        githubWarmPollIntervalSec: 900,
        githubColdPollIntervalSec: 86_400,
        slackWarmPollIntervalSec: 900,
        slackColdPollIntervalSec: 86_400,
        attentionWindowPollIntervalSec: 30,
        rotationFetchIntervalSec: 60,
        detectorIncrementalIntervalSec: 30,
        detectorScheduledIntervalSec: 300,
        calendarPollIntervalSec: 60,
        focusModePollIntervalSec: 60,
        spaceTransitionCoalesceWindowSec: 2,
        appleScriptDefaultTimeoutSec: 1.0,
        appleScriptPerAppTimeoutOverridesJson: "{\"us.zoom.xos\":3.0}",
        cgEventTapMinuteBucketSec: 60,
        clipboardPollIntervalSec: 60,
        wifiPollIntervalSec: 60,
        localFilesCoalesceWindowSec: 2,
        screenshotDirectoryOverridePath: ""
    )
}
