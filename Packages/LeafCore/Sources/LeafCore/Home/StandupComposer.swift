//
//  StandupComposer.swift
//  Track-10 T8 — pure-function composition helpers for the Home Zone-5
//  RECAP + EOD blocks. Mirrors TeamNRowComposer / YoureOnRowComposer:
//  static helpers, no captures, deterministic given the same inputs. View
//  body (RecapBlock / EodBlock) is a thin shell over these primitives.
//
//  Compose's `now` is the staleness-window clock (24h cutoff). View-tier
//  `RecapBlock.init`'s separate `now` is the hour-bucket clock for the
//  auto-reveal `@State`. Different temporal lenses — F-CTO-T8-G — by
//  design; they MUST not be merged.
//

import Foundation

/// Static helpers consumed by `RecapBlock` + `EodBlock`. All functions
/// pure + deterministic. Empty / nil composition routes to view-tier
/// empty-state path (master spec §3.10).
public enum StandupComposer {

    // MARK: - Tunable constants (composer-scoped)

    /// 24h hardcoded per Brainstorm Q7. Items older than this surface in
    /// the standup "still waiting" list. Boundary inclusive of 24h0m1ms.
    public static let stalenessCutoffMs: Int64 = 24 * 60 * 60 * 1000

    /// How many `closed LEAF-NN` keys composer collects from yesterday's
    /// feed. Preserves data for future surfaces (e.g. MCP get_standup_summary
    /// carry C-T8-4); view-tier clamps via `issueKeysRenderCap` per
    /// F-CTO-T8-N.
    public static let issueKeysCollectionCap = 5

    /// How many `closed LEAF-NN` keys the view renders inline before
    /// switching to "+N more" overflow. Matches T5 SinceLastActiveBlock
    /// precedent for the line-length budget at narrow Zone-5 widths.
    public static let issueKeysRenderCap = 3

    /// Max waiting items surfaced per block (RECAP + EOD share the same
    /// 3-cap so the Zone-5 blocks don't blow past their natural height).
    public static let waitingCap = 3

    /// Max open blockers surfaced per block.
    public static let blockersCap = 3

    // MARK: - Top-level compose

    /// Top-level orchestrator. Returns a snapshot with `nil` children when
    /// nothing meaningful exists for either window (view-tier renders the
    /// empty-state copy in that case). Always returns a wrapper — caller
    /// writes `standupRecap = snapshot` unconditionally.
    ///
    /// Inputs (10):
    /// - `yesterdayActivity` / `todayActivity` — `recentActivityFeed` windows
    ///   (callers compute the day boundaries; this composer is window-agnostic)
    /// - `yesterdayMetrics` / `todayMetrics` — `todayMetrics(now:)` for the
    ///   commits-per-day count (other TodayMetrics fields ignored — they're
    ///   read by the TODAY block)
    /// - `actionableItems` — the existing `InboxItem` list from
    ///   `inboxItems(filter:.all)`; composer filters to stale + caps
    /// - `openBlockers` — currently-OPEN blockers (carry C-T8-1 covers
    ///   resolved-today substrate; out of T8 scope)
    /// - `currentTask` — the same `TaskIdentity` Zone-4 YOU'RE ON consumes
    /// - `latestStop` — `recentWhereStopped[0]` for the EOD "Tomorrow: resume"
    ///   line
    /// - `now` — staleness-window anchor; NOT the hour-bucket anchor (the
    ///   view-tier RecapBlock derives its own `now` for auto-reveal)
    public static func compose(
        yesterdayActivity: [ActivityFeedItem],
        todayActivity: [ActivityFeedItem],
        yesterdayMetrics: TodayMetrics,
        todayMetrics: TodayMetrics,
        actionableItems: [InboxItem],
        openBlockers: [Blocker],
        currentTask: TaskIdentity?,
        latestStop: WhereStoppedSnapshot?,
        now: Date
    ) -> StandupSnapshot {
        let waitingItems = staleWaitingItems(actionableItems, now: now)
        let blockers = Array(openBlockers.prefix(blockersCap))

        let recap = StandupRecap(
            yesterdayCommitsCount: yesterdayMetrics.commitsCount,
            yesterdayClosedLinearKeys: extractCompletedLinearKeys(yesterdayActivity),
            yesterdayReviewedPRsCount: countReviewedPRs(yesterdayActivity),
            todayContinuing: currentTask,
            waitingItems: waitingItems,
            openBlockers: blockers
        )
        let eod = StandupEod(
            todayCommitsCount: todayMetrics.commitsCount,
            todayClosedLinearKeys: extractCompletedLinearKeys(todayActivity),
            todayReviewedPRsCount: countReviewedPRs(todayActivity),
            tomorrowResume: latestStop,
            carryWaitingItems: waitingItems,
            carryOpenBlockers: blockers
        )
        return StandupSnapshot(
            recap: recap.isEmpty ? nil : recap,
            eod: eod.isEmpty ? nil : eod
        )
    }

    // MARK: - Linear key extraction

    /// Pulls unique LEAF-NN keys from completed Linear transitions where I
    /// am the actor. F-CTO-T8-B — sort by `ts desc` BEFORE dedupe so a
    /// re-closed issue keeps its most-recent occurrence position; cap at
    /// `issueKeysCollectionCap`.
    public static func extractCompletedLinearKeys(_ feed: [ActivityFeedItem]) -> [String] {
        let sorted = feed.sorted { $0.ts > $1.ts }
        var seen = Set<String>()
        var out: [String] = []
        for item in sorted {
            guard item.source == .linear,
                item.actorIsMe,
                item.eventKind == LinearActivityKinds.statusTransitionCompletedKind,
                let ref = item.targetRef, !ref.isEmpty
            else { continue }
            if seen.insert(ref).inserted {
                out.append(ref)
                if out.count == issueKeysCollectionCap { break }
            }
        }
        return out
    }

    /// Counts PR review events I authored. Exact-match
    /// `gh_pr_review_authored` (F-CTO-T8-S verified) — does NOT count
    /// `gh_pr_review_requested` (that's "review requested OF me", not "I
    /// reviewed").
    public static func countReviewedPRs(_ feed: [ActivityFeedItem]) -> Int {
        feed.reduce(0) { count, item in
            (item.source == .github
                && item.actorIsMe
                && item.eventKind == GitHubActivityKinds.prReviewAuthoredKind)
                ? count + 1 : count
        }
    }

    // MARK: - Waiting-item filter

    /// Keeps items older than `stalenessCutoffMs` (boundary: > cutoff =
    /// included; <= cutoff = excluded). Sorts by `severity.sortRank` asc
    /// then oldest first (`createdAtMs` asc). Caps at `waitingCap`.
    public static func staleWaitingItems(_ items: [InboxItem], now: Date) -> [InboxItem] {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let filtered = items.filter { (nowMs - $0.createdAtMs) > stalenessCutoffMs }
        let sorted = filtered.sorted { a, b in
            if a.severity.sortRank != b.severity.sortRank {
                return a.severity.sortRank < b.severity.sortRank
            }
            return a.createdAtMs < b.createdAtMs
        }
        return Array(sorted.prefix(waitingCap))
    }

    // MARK: - View-tier render helpers

    /// "closed GUN-204" / "closed GUN-204, GUN-187" / "closed GUN-204,
    /// GUN-187, GUN-103 +2 more" — overflow suffix appears once render cap
    /// is hit. Returns nil for empty input so callers can drop the segment.
    public static func renderLinearKeysClause(_ keys: [String]) -> String? {
        guard !keys.isEmpty else { return nil }
        let shown = Array(keys.prefix(issueKeysRenderCap))
        let overflow = keys.count - shown.count
        let body = shown.joined(separator: ", ")
        if overflow > 0 {
            return "closed \(body) +\(overflow) more"
        }
        return "closed \(body)"
    }

    /// `< 60s` → "now"; `< 60m` → "Nm"; `< 24h` → "Nh"; `>= 24h` → "Nd".
    /// POSIX-locale equivalent without DateFormatter — pure integer
    /// arithmetic so calling 1000× per render is allocation-free.
    public static func formatItemAge(_ createdAtMs: Int64, now: Date) -> String {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let deltaMs = max(0, nowMs - createdAtMs)
        let seconds = deltaMs / 1_000
        if seconds < 60 { return "now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        return "\(days)d"
    }

    /// "PR #141 awaiting your review (2d)" — composes title + (age).
    /// Title is read off `InboxItem.title` directly (already allow-listed
    /// content per ADR-010; bodies / excerpts forbidden).
    public static func renderWaitingBullet(_ item: InboxItem, now: Date) -> String {
        let age = formatItemAge(item.createdAtMs, now: now)
        return "\(item.title) (\(age))"
    }

    /// "Sasha input on relay rotation API shape" — `Blocker.excerpt`
    /// already excerpted at detector emit time (Track-1 D3 substrate).
    public static func renderBlockerBullet(_ blocker: Blocker) -> String {
        blocker.excerpt
    }

    // MARK: - Hour-bucket auto-reveal

    /// RECAP morning brief: expanded by default during `[06:00, 11:00)`.
    /// Used by `RecapBlock.init` to seed `@State expanded`. Master spec §3.7.
    public static func isRecapExpanded(atHour hour: Int) -> Bool {
        (6..<11).contains(hour)
    }

    /// EOD end-of-day: expanded by default during `[17:00, 23:00)`.
    /// Used by `EodBlock.init` to seed `@State expanded`. Master spec §3.7.
    public static func isEodExpanded(atHour hour: Int) -> Bool {
        (17..<23).contains(hour)
    }
}
