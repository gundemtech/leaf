import Foundation

/// Track-10 T8 — bundled value type powering the Home Zone-5 standup helper
/// (RECAP morning brief + EOD end-of-day). Composed once per
/// `InsightsReader.refresh()` via `StandupComposer.compose(...)`. Both inner
/// types are intentionally structured (raw counts + identifier arrays +
/// reused snapshots) rather than pre-formatted strings — view-tier composes
/// display strings via `StandupComposer.render*` so locale + DateFormatter
/// allocation lives at render time (NOT in the substrate).
///
/// Empty-state routing: `recap == nil || recap.isEmpty` ⇒ RECAP block shows
/// "Nothing captured yesterday."; analogous for EOD. The view layer takes
/// precedence over `hasCleanBreak` per master spec §A8.2 + F-CTO-T8-I
/// (isEmpty path overrides "Clean break" line when nothing to recap).
///
/// Codable conformance intentionally omitted (T7 precedent F-CTO-A):
/// nested `InboxItem` / `Blocker` / `TaskIdentity` / `WhereStoppedSnapshot`
/// are not Codable, so Codable on this wrapper would force blast-radius
/// migrations elsewhere. Hashable + Sendable are sufficient for SwiftUI
/// diffing and cross-actor passing.
public struct StandupSnapshot: Equatable, Hashable, Sendable {
    /// `nil` ⇒ RecapBlock renders empty-state path (no morning brief).
    public let recap: StandupRecap?
    /// `nil` ⇒ EodBlock renders empty-state path (no end-of-day brief).
    public let eod: StandupEod?

    public init(recap: StandupRecap?, eod: StandupEod?) {
        self.recap = recap
        self.eod = eod
    }
}

/// Morning brief — yesterday's wrap + today's anchor. Auto-expands in
/// `RecapBlock` at view-init when hour ∈ [06, 11) (master spec §3.7).
public struct StandupRecap: Equatable, Hashable, Sendable {
    /// Yesterday GitHub commits authored by me (count only — no SHAs / messages).
    public let yesterdayCommitsCount: Int
    /// Yesterday Linear issues I closed (LEAF-NN / GUN-NN keys). Composer
    /// collects up to 5; view renders first 3 + "+N more" overflow per
    /// F-CTO-T8-N.
    public let yesterdayClosedLinearKeys: [String]
    /// Yesterday GitHub PR reviews I authored (count only).
    public let yesterdayReviewedPRsCount: Int
    /// "Today: continuing GUN-208" anchor. Reuses Track-10 T2 `TaskIdentity`
    /// to share moat with YOU'RE ON Zone-4 (intentional duplication; see
    /// F-CTO-T8-D rationale — different temporal voice).
    public let todayContinuing: TaskIdentity?
    /// Stale waiting items (`createdAtMs > 24h ago`), capped at 3 by composer.
    public let waitingItems: [InboxItem]
    /// Open blockers (currently no resolved-today substrate — carry C-T8-1).
    public let openBlockers: [Blocker]

    public init(
        yesterdayCommitsCount: Int,
        yesterdayClosedLinearKeys: [String],
        yesterdayReviewedPRsCount: Int,
        todayContinuing: TaskIdentity?,
        waitingItems: [InboxItem],
        openBlockers: [Blocker]
    ) {
        self.yesterdayCommitsCount = yesterdayCommitsCount
        self.yesterdayClosedLinearKeys = yesterdayClosedLinearKeys
        self.yesterdayReviewedPRsCount = yesterdayReviewedPRsCount
        self.todayContinuing = todayContinuing
        self.waitingItems = waitingItems
        self.openBlockers = openBlockers
    }

    /// View-layer empty-state branch driver. `todayContinuing` alone is NOT
    /// enough to consider the recap meaningful — without any backing yesterday
    /// signal the recap line reads as broken ("just continuing X with no
    /// context"). Master spec §3.10 + Brainstorm Q5 — empty-state copy is
    /// "Nothing captured yesterday.".
    public var isEmpty: Bool {
        yesterdayCommitsCount == 0
            && yesterdayClosedLinearKeys.isEmpty
            && yesterdayReviewedPRsCount == 0
            && waitingItems.isEmpty
            && openBlockers.isEmpty
    }
}

/// End-of-day brief — today's wrap + tomorrow's resume anchor + remaining
/// carries. Auto-expands in `EodBlock` at view-init when hour ∈ [17, 23).
public struct StandupEod: Equatable, Hashable, Sendable {
    public let todayCommitsCount: Int
    public let todayClosedLinearKeys: [String]
    public let todayReviewedPRsCount: Int
    /// "Tomorrow: resume <anchor>" — reuses `WhereStoppedSnapshot` from
    /// Zone-1 RESUME hero (intentional reuse; see F-CTO-T8-E rationale —
    /// narrow surface read of anchorBundleID / anchorFilePath /
    /// recentLastCommit?.message).
    public let tomorrowResume: WhereStoppedSnapshot?
    public let carryWaitingItems: [InboxItem]
    public let carryOpenBlockers: [Blocker]

    public init(
        todayCommitsCount: Int,
        todayClosedLinearKeys: [String],
        todayReviewedPRsCount: Int,
        tomorrowResume: WhereStoppedSnapshot?,
        carryWaitingItems: [InboxItem],
        carryOpenBlockers: [Blocker]
    ) {
        self.todayCommitsCount = todayCommitsCount
        self.todayClosedLinearKeys = todayClosedLinearKeys
        self.todayReviewedPRsCount = todayReviewedPRsCount
        self.tomorrowResume = tomorrowResume
        self.carryWaitingItems = carryWaitingItems
        self.carryOpenBlockers = carryOpenBlockers
    }

    public var isEmpty: Bool {
        todayCommitsCount == 0
            && todayClosedLinearKeys.isEmpty
            && todayReviewedPRsCount == 0
            && tomorrowResume == nil
            && carryWaitingItems.isEmpty
            && carryOpenBlockers.isEmpty
    }

    /// True when both carry arrays are empty — drives the "Clean break:
    /// nothing critical hanging" line in `EodBlock`. View-layer must check
    /// `isEmpty` first (F-CTO-T8-I): when the user did nothing today and
    /// has no carries, the block renders "Nothing captured today yet."
    /// instead of "Clean break".
    public var hasCleanBreak: Bool {
        carryWaitingItems.isEmpty && carryOpenBlockers.isEmpty
    }
}
