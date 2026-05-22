# Phase 8.1 — Substrate + matching engine · Spec

**Status:** Draft (2026-05-18). Promoted to "Active" after user review gate closes.
**Track:** Track 8 — Home as Operational Console (`docs/superpowers/specs/2026-05-18-track-8-home-ux-design.md`).
**Stage:** 3 (Spec write) of the 8-stage per-phase workflow (`conventions.md`).
**Predecessors:** Track 8 design spec §9 P1 (locked contract).

---

## 1. Goal & scope

Phase 8.1 ships the **substrate-only** foundation for Track 8 Home redesign. No UI work. Subsequent phases (P2-P9) wire Track 8 blocks on top of this substrate.

**In scope:**

- 5 new public types in `LeafCore.Insights`: `TaskIdentity`, `TeammateMatch` (+ `MatchConfidence`, `MatchRule`), `InboxItem` (+ `InboxKind`, `InboxSeverity`, `InboxFilter`), `TodayMetrics` (+ `SurfacePill`), `YouNowState` (+ associated structs).
- 2 pure deriver functions: `SameTaskMatcher.match(...)`, `YouNowStateDeriver.derive(...)`.
- 1 new protocol: `TeammatePresenceReader` (stub-impl until Phase 5.4 lands `presence_history`).
- 5 new `DerivedInsights` protocol methods (as extension defaults): `currentTaskIdentity()`, `sameTaskTeammates(rule:)`, `inboxItems(filter:query:)`, `todayMetrics(now:)`, `youNowState(now:)`.
- LeafCorePrivate `ProdInsights` overrides for all 5 methods.
- Tests: pure-deriver tests (LeafCoreTests) + integration tests with in-memory GRDB (LeafCorePrivateTests).

**Out of scope (deferred to later phases):**

- All UI files (P2-P9 own them — `HomeView` rewrite, block files, `AnalyticsView`).
- `presence_history` migration + WS broadcast + envelope (Phase 5.4 owns).
- Real `TeammatePresenceReader` implementation reading from `presence_history` (Phase 5.4 lights it up; P1 ships stub).
- Sentinel-leakage test for `body_excerpt` on inbox path (spec §7 of track spec assigns this to P6).
- New event_kinds / migrations / MCP tools / `ShareEventTypeKey` registry changes (Track 8 §1 hard exclusion).
- `LinearStuckScanner` integration — open-questions/blockers from the existing detection tables are sufficient for INBOX. Stuck-scanner output already lives in `blockers` per Track-1 D3.

---

## 2. Contract gap: `presence_history` not yet migrated

Track 8 design spec §6.1 lists `presence_history` as "reuse as-is". Migration inventory M001-M018, M024, M026, M027 contains no `presence_history` table — Phase 5.4 owns this migration (per `current-state.md` "Phase 5.4 (parallel)" line).

**Mitigation:** Phase 8.1 introduces `TeammatePresenceReader` as a protocol shim. Default impl `StubTeammatePresenceReader` returns `[]`. The matching engine (`SameTaskMatcher`) is fully testable on injected fixtures — it does not depend on storage at all. UI in P5 will render the empty-state branch until Phase 5.4 lights up the real reader against `presence_history`.

When Phase 5.4 ships, the only change needed to wake up WITH YOU ON THIS is implementing `DBTeammatePresenceReader` in LeafCorePrivate and wiring it through factory registration. No API surface changes in `DerivedInsights` or `SameTaskMatcher`.

---

## 3. New types (LeafCore public)

All types `Equatable`, `Hashable`, `Sendable`. `Codable` only where storage / cross-process transit is plausible (none for P1, but cheap to add — Track 7 pattern is "Codable when in doubt").

### 3.1 `TaskIdentity.swift`

```swift
public struct TaskIdentity: Equatable, Hashable, Sendable {
    public let linearID: String?
    public let branch: String?
    public let repo: String?
    public let workspacePath: String?

    public init(linearID: String? = nil, branch: String? = nil, repo: String? = nil, workspacePath: String? = nil)

    public var isEmpty: Bool { linearID == nil && branch == nil && repo == nil && workspacePath == nil }
}
```

`isEmpty` is the signal that `currentTaskIdentity()` returned a "nothing meaningful" record (e.g. cold boot, no presence yet) — distinct from `nil` (no presence_state row at all).

### 3.2 `TeammateMatch.swift`

```swift
public struct TeammateMatch: Equatable, Hashable, Sendable {
    public let memberID: String          // stable team_members.id
    public let displayName: String
    public let currentApp: String?       // app name from teammate snapshot (nil = unknown)
    public let durationSec: Int          // seconds since teammate became active (0 if unknown)
    public let confidence: MatchConfidence
    public let contextLabel: String      // human-readable badge text ("LEAF-204", "same branch", "adjacent branch")
    public let lastActivityAtMs: Int64   // teammate snapshot timestamp (matches TeammateSnapshot.lastActivityAtMs)

    public init(memberID: String, displayName: String, currentApp: String?, durationSec: Int,
                confidence: MatchConfidence, contextLabel: String, lastActivityAtMs: Int64)
}

public enum MatchConfidence: String, Equatable, Hashable, Sendable {
    case onSameLinearIssue
    case onSameBranch
    case onAdjacentBranch
}

public enum MatchRule: String, Equatable, Hashable, Sendable {
    case hierarchical    // Track-8 default; future rules added behind this enum
}
```

`memberID` is the stable identifier used in Team tab — does not leak PII; `displayName` comes from `team_members.display_name` (already-authored field in M007).

### 3.3 `TeammateSnapshot.swift` (input type for `SameTaskMatcher`)

```swift
public struct TeammateSnapshot: Equatable, Hashable, Sendable {
    public let memberID: String
    public let displayName: String
    public let linearID: String?
    public let branch: String?
    public let repo: String?
    public let currentApp: String?
    public let lastActivityAtMs: Int64

    public init(memberID: String, displayName: String, linearID: String?, branch: String?,
                repo: String?, currentApp: String?, lastActivityAtMs: Int64)
}
```

This is the *input* to the matcher — the reader produces these, the matcher consumes them. Decoupled from any storage shape.

### 3.4 `InboxItem.swift`

```swift
public struct InboxItem: Equatable, Hashable, Sendable, Identifiable {
    public let id: String                // stable composite ID for SwiftUI list identity
    public let kind: InboxKind
    public let severity: InboxSeverity
    public let title: String             // full artifact title; never opaque "PR #18"
    public let sourceMeta: String        // "PR #N · repo · by author · {age}"
    public let sourceURL: URL?           // GitHub/Linear/Slack canonical link
    public let aggregatedCount: Int      // 1 unless aggregation rule collapsed multiple events
    public let createdAtMs: Int64        // most recent contributing event ts (for sort)

    public init(id: String, kind: InboxKind, severity: InboxSeverity, title: String,
                sourceMeta: String, sourceURL: URL?, aggregatedCount: Int, createdAtMs: Int64)
}

public enum InboxKind: String, Equatable, Hashable, Sendable {
    case reviewRequest
    case commentOnMyWork
    case mention
    case openQuestion
    case blocker
}

public enum InboxSeverity: String, Equatable, Hashable, Sendable {
    case danger    // 🔴 — explicit mention OR comment on my open PR/issue in last 30 min
    case warn      // 🟡 — pending review request, open question, blocker
    case muted     // ⚪ — viewed (UI-side; P1 always emits .danger/.warn; .muted applied by UI session state)
}

public enum InboxFilter: String, Equatable, Hashable, Sendable {
    case all
    case reviews        // .reviewRequest
    case questions      // .openQuestion
    case mentions       // .mention
}
```

Future `InboxFilter` cases (`.comments`, `.blockers`, `.notes`, `.tasks`) added as features ship. Track 8 §1 hides `.notes` / `.tasks` chips until Track 9+.

### 3.5 `TodayMetrics.swift`

```swift
public struct TodayMetrics: Equatable, Hashable, Sendable {
    public let focusedMin: Int
    public let aiRatio: Double            // 0.0...1.0
    public let sessionsCount: Int
    public let switchCount: Int           // contextSwitchRate × period duration, rounded
    public let commitsCount: Int
    public let surfacePills: [SurfacePill]

    public static let empty = TodayMetrics(focusedMin: 0, aiRatio: 0, sessionsCount: 0,
                                            switchCount: 0, commitsCount: 0, surfacePills: [])

    public init(focusedMin: Int, aiRatio: Double, sessionsCount: Int, switchCount: Int,
                commitsCount: Int, surfacePills: [SurfacePill])
}

public struct SurfacePill: Equatable, Hashable, Sendable, Identifiable {
    public let id: String      // surface key ("claude_code", "xcode", "linear", etc.)
    public let label: String   // display label ("Claude")
    public let count: Int

    public init(id: String, label: String, count: Int)
}
```

`surfacePills` is sorted by count desc in `ProdInsights`. UI in P3 owns the "+N" overflow logic when N > visible cap. Surface keys map 1:1 to `HomeSurface` enum cases (Track-7 P1 catalog) — Prod query uses `HomeSurface.allCases` as authoritative list.

### 3.6 `YouNowState.swift`

```swift
public enum YouNowState: Equatable, Hashable, Sendable {
    case active(YouNowActive)
    case inMeeting(YouNowMeeting)
    case deepWorkFocus(YouNowFocus)
    case away(YouNowAway)
}

public struct YouNowActive: Equatable, Hashable, Sendable {
    public let app: String
    public let contextLabel: String?     // file basename / window title (already redacted upstream)
    public let branch: String?
    public let linearID: String?
    public let durationSec: Int
    public let intensityBars: Int        // 0...4 (idle→peak); existing collector substrate already produces this

    public init(app: String, contextLabel: String?, branch: String?, linearID: String?,
                durationSec: Int, intensityBars: Int)
}

public struct YouNowMeeting: Equatable, Hashable, Sendable {
    public let titleIfAvailable: String?   // EventKit allow-listed; nil if Zoom-only
    public let startedAtMs: Int64
    public let endsAtMsIfAvailable: Int64?
    public let source: MeetingSource

    public init(titleIfAvailable: String?, startedAtMs: Int64,
                endsAtMsIfAvailable: Int64?, source: MeetingSource)
}

public enum MeetingSource: String, Equatable, Hashable, Sendable {
    case eventKit
    case zoom
    case both
}

public struct YouNowFocus: Equatable, Hashable, Sendable {
    public let modeName: String?         // Focus mode name; nil if INFocusStatusCenter only reports boolean
    public let app: String?
    public let contextLabel: String?
    public let durationSec: Int

    public init(modeName: String?, app: String?, contextLabel: String?, durationSec: Int)
}

public struct YouNowAway: Equatable, Hashable, Sendable {
    public let reason: AwayReason
    public let lastApp: String?
    public let lastContextLabel: String?
    public let lastLinearID: String?
    public let idleSec: Int

    public init(reason: AwayReason, lastApp: String?, lastContextLabel: String?,
                lastLinearID: String?, idleSec: Int)
}

public enum AwayReason: String, Equatable, Hashable, Sendable {
    case screenLocked
    case idle
    case sleep
}
```

Idle-Resume CTA decision (≤24h, has LEAF-ID, app in `LocalAppsStore.enabled`) lives in P4 (UI) — `YouNowAway` carries enough payload (`lastApp`, `lastLinearID`, `idleSec`) for the UI to decide.

---

## 4. Pure derivers (LeafCore public)

### 4.1 `SameTaskMatcher.swift`

```swift
public enum SameTaskMatcher {
    /// Matches teammates against my current task identity using the hierarchical rule:
    /// (1) onSameLinearIssue — both sides resolve to identical LEAF-NN.
    /// (2) onSameBranch — identical branch name AND neither side has LEAF-NN (rule 1 didn't fire).
    /// (3) onAdjacentBranch — same repo AND branch names share ≥ adjacentMinSharedSegments
    ///     common segments after splitting on `/` and `-`.
    /// Returns matches sorted: confidence priority desc, then lastActivityAtMs desc.
    /// Teammates not matching any rule are omitted (fall through to Team tab).
    public static func match(myIdentity: TaskIdentity,
                             teammates: [TeammateSnapshot],
                             rule: MatchRule) -> [TeammateMatch]
}
```

Constants (private static, file-local):

```swift
private static let adjacentMinSharedSegments = 3
```

**Algorithm:**

1. If `myIdentity.isEmpty == true` → return `[]` (cannot match anything).
2. For each `t in teammates`:
   - Compute `t.linearID` (use as-given — extractor already ran upstream when building snapshot).
   - Rule 1: if `myIdentity.linearID != nil && t.linearID == myIdentity.linearID` → `.onSameLinearIssue`. `contextLabel = "on \(linearID)"`. Continue.
   - Rule 2: if `myIdentity.linearID == nil && t.linearID == nil && myIdentity.branch != nil && t.branch == myIdentity.branch` → `.onSameBranch`. `contextLabel = "same branch"`. Continue.
   - Rule 3: if `myIdentity.repo != nil && t.repo == myIdentity.repo && myIdentity.branch != nil && t.branch != nil && sharedSegmentCount(a: myIdentity.branch!, b: t.branch!) >= 3` → `.onAdjacentBranch`. `contextLabel = "adjacent branch"`. Continue.
   - Otherwise → skip.
3. Sort: confidence priority (`onSameLinearIssue` > `onSameBranch` > `onAdjacentBranch`), then `TeammateMatch.lastActivityAtMs` desc, then `displayName` ascending (stable tie-breaker for tests).

**`sharedSegmentCount` helper** (private): splits each string by `/` and `-`, lowercases, counts longest common prefix segment count. `feature/track-8-home` vs `feature/track-8-analytics` → split into `["feature", "track", "8", "home"]` and `["feature", "track", "8", "analytics"]` → prefix count = 3.

### 4.2 `YouNowStateDeriver.swift`

```swift
public struct YouNowInputs: Equatable, Sendable {
    public let frontmostAppName: String?
    public let frontmostBundleID: String?
    public let contextLabel: String?       // window title, file basename — already redacted upstream
    public let branch: String?             // git branch of frontmost workspace, if any
    public let linearID: String?           // extracted from branch / context already at input boundary
    public let activeSessionStartedAtMs: Int64?
    public let intensityBars: Int          // 0...4 from intensity_aggregates
    public let idleSec: Int
    public let screenLocked: Bool
    public let meetingActive: Bool
    public let meetingTitle: String?
    public let meetingStartedAtMs: Int64?
    public let meetingEndsAtMs: Int64?
    public let meetingSource: MeetingSource?
    public let focusActive: Bool
    public let focusModeName: String?
    public let nowMs: Int64

    public init(/* all let above */)
}

public enum YouNowStateDeriver {
    /// Priority: inMeeting > deepWorkFocus > active > away.
    /// Idle threshold default: 300 seconds (5 min). Configurable via `idleThresholdSec` parameter.
    public static func derive(_ inputs: YouNowInputs, idleThresholdSec: Int = 300) -> YouNowState
}
```

**Algorithm:**

1. If `inputs.meetingActive == true` → `.inMeeting(YouNowMeeting(titleIfAvailable: inputs.meetingTitle, startedAtMs: inputs.meetingStartedAtMs ?? inputs.nowMs, endsAtMsIfAvailable: inputs.meetingEndsAtMs, source: inputs.meetingSource ?? .eventKit))`.
2. Else if `inputs.focusActive == true && inputs.idleSec < idleThresholdSec` → `.deepWorkFocus(YouNowFocus(...))`. `durationSec = (nowMs - sessionStart)/1000` if available, else `0`.
3. Else if `inputs.screenLocked == true` → `.away(YouNowAway(reason: .screenLocked, lastApp: inputs.frontmostAppName, lastContextLabel: inputs.contextLabel, lastLinearID: inputs.linearID, idleSec: inputs.idleSec))`.
4. Else if `inputs.idleSec >= idleThresholdSec` → `.away(YouNowAway(reason: .idle, ...))`.
5. Else if `inputs.frontmostAppName != nil` → `.active(YouNowActive(app: appName!, contextLabel: inputs.contextLabel, branch: inputs.branch, linearID: inputs.linearID, durationSec: derived, intensityBars: inputs.intensityBars))`.
6. Else → `.away(YouNowAway(reason: .idle, lastApp: nil, lastContextLabel: nil, lastLinearID: nil, idleSec: inputs.idleSec))` (degenerate "nothing captured" case).

Sleep state (`.sleep`) is reserved for Phase 4.10 sleep-collector output — emitted when `system_slept` event is the most recent context event without a wake counterpart. P1 deriver does not consume sleep events; UI hands it `.idle` reason until that wiring lands.

---

## 5. `TeammatePresenceReader` protocol

```swift
/// Returns most-recent snapshot per teammate, where snapshot lastActivityAtMs is within
/// the requested freshness window. Empty array if no teammates / pre-Phase 5.4 / relay disconnected.
public protocol TeammatePresenceReader: Sendable {
    func recentTeammateSnapshots(maxAge: TimeInterval, now: Date) throws -> [TeammateSnapshot]
}

public struct StubTeammatePresenceReader: TeammatePresenceReader {
    public init() {}
    public func recentTeammateSnapshots(maxAge: TimeInterval, now: Date) throws -> [TeammateSnapshot] { [] }
}
```

Factory pattern (mirrors `DerivedInsightsFactory`):

```swift
public enum TeammatePresenceReaderFactory {
    nonisolated(unsafe) private static var provider: ((Database) -> any TeammatePresenceReader)?
    public static func register(_ fn: @escaping (Database) -> any TeammatePresenceReader)
    public static func make(database: Database) -> any TeammatePresenceReader   // returns Stub if no registration
}
```

Phase 5.4 replaces the stub via `TeammatePresenceReaderFactory.register(DBTeammatePresenceReader.init)` from LeafCorePrivate startup hook. P1 ships the factory + stub; Prod-side ProdInsights consumes via factory `make`.

---

## 6. `DerivedInsights` protocol additions

All 5 added as **extension defaults** matching Track-7 P3 pattern (graceful for StubInsights / iOS-future).

```swift
// In DerivedInsights.swift

func currentTaskIdentity() throws -> TaskIdentity?
func sameTaskTeammates(rule: MatchRule) throws -> [TeammateMatch]
func inboxItems(filter: InboxFilter, query: String?) throws -> [InboxItem]
func todayMetrics(now: Date) throws -> TodayMetrics
func youNowState(now: Date) throws -> YouNowState

// In extension defaults:
extension DerivedInsights {
    func currentTaskIdentity() throws -> TaskIdentity? { nil }
    func sameTaskTeammates(rule: MatchRule) throws -> [TeammateMatch] { [] }
    func inboxItems(filter: InboxFilter, query: String?) throws -> [InboxItem] { [] }
    func todayMetrics(now: Date) throws -> TodayMetrics { .empty }
    func youNowState(now: Date) throws -> YouNowState {
        .away(YouNowAway(reason: .idle, lastApp: nil, lastContextLabel: nil, lastLinearID: nil, idleSec: 0))
    }
}
```

`StubInsights` inherits defaults; no explicit override needed.

---

## 7. `ProdInsights` overrides (LeafCorePrivate)

Each override lives in its own `ProdInsights+<Method>.swift` file under `Packages/LeafCore/Sources/LeafCorePrivate/Prod/Insights/`. Pattern mirrors existing `ProdInsights+RecentSessions.swift`.

### 7.1 `ProdInsights+CurrentTaskIdentity.swift`

Read `presence_state.derived.state_json` (Phase 4.9 derived row — currently composed but `derived_mode` is NULL; the json carries `frontmost_app`, `branch`, `repo`, `workspace_path` fields populated by Track-4 S2 + Track-6 P2 substrate). Apply `LinearIDExtractor.extract(text: branch, knownPrefixes: prefixes)`. Returns `TaskIdentity(linearID: extracted, branch: branch, repo: repo, workspacePath: workspacePath)`. Empty branch + empty linearID → returns nil rather than `.empty` instance (caller distinguishes "no data yet" from "matched nothing").

### 7.2 `ProdInsights+TodayMetrics.swift`

Single composite method calling existing `DerivedInsights` methods on `self`:

```swift
let today = DateInterval.today(in: .current, now: now)   // helper added if not present
let focusedMin = try focusSessions(period: today).reduce(0) { $0 + $1.durationMin }
let aiRatio = try aiActivityBreakdown(period: today).ratio
let sessionsCount = try focusSessions(period: today).count
let switchRate = try contextSwitchRate(period: today)
let switchCount = Int((switchRate * today.duration / 60).rounded())   // switches per minute × min
let commitsCount = try queryCommitCountToday(now: now)
let surfacePills = try queryEventCountsBySurface(today: today, surfaces: HomeSurface.allCases)
return TodayMetrics(...)
```

`queryCommitCountToday`: counts events in the `[startMs, endMs)` window whose event_kind is one of `git_commit` or `gh_push` (broad union). `gh_push` collapses to 1 commit but de-duplicating against local-git-commit events is left to whichever collector ships the canonical local-commit kind. Real query body lives in LeafCorePrivate moat. (See R-1 in §10.)

`queryEventCountsBySurface`: iterates `HomeSurface.allCases` and emits one `SurfacePill` per surface with non-zero count using the existing per-surface event_kind union map already in Track-7 P2 surface view models. Sorted by count desc, capped at 8 entries (UI handles overflow).

### 7.3 `ProdInsights+SameTaskTeammates.swift`

```swift
let reader = TeammatePresenceReaderFactory.make(database: database)
let snapshots = try reader.recentTeammateSnapshots(maxAge: 600, now: Date())   // 10-min freshness
guard let me = try currentTaskIdentity(), !me.isEmpty else { return [] }
return SameTaskMatcher.match(myIdentity: me, teammates: snapshots, rule: rule)
```

Returns `[]` until Phase 5.4 wires the real reader. Tests inject snapshots directly via a fake reader.

### 7.4 `ProdInsights+InboxItems.swift`

Composes per-kind queries:

```swift
let allItems = try queryReviewRequests() + queryCommentsOnMyWork() + queryMentions()
            + queryOpenQuestionsForMe() + queryBlockersAffectingMe()
let dedupedByPR = aggregateByTarget(allItems)
let filtered = applyFilter(dedupedByPR, filter)
let searched = query.map { applySearch(filtered, query: $0) } ?? filtered
return sortBySeverityThenAge(searched)
```

Privacy invariant: each per-kind query reads ONLY already-allow-listed payload fields per Track-3 D2/D3 parser walkbacks — PR title, issue title, comment `body_excerpt` (60-char cap at parser boundary, already enforced upstream). No new fields touched.

`viewerLogin` for "comment on my work" / "mention" filters comes from `presence_state.github.state_json.viewer_login`. Missing → that branch returns `[]`.

14-day cap (per Track 8 OQ-T8-4) hardcoded as `private static let inboxItemMaxAgeDays = 14`.

Aggregation rule: items with the same `(kind, sourceURL, target_artifact)` collapse to one row with `aggregatedCount` reflecting collapsed count, keeping the most recent `createdAtMs` + most recent `body_excerpt` as the visible title meta.

### 7.5 `ProdInsights+YouNowState.swift`

Collects `YouNowInputs` from:
- `presence_state.derived.state_json` (frontmost app, bundle ID, context, branch).
- Most recent `meeting_state_entered` / `meeting_state_exited` events from M001 events (last 24h scan).
- `zoom_meeting_started` / `_ended` events for Zoom-source meetings; cross-link via `event_links.link_kind = 'zoom_to_calendar_meeting'` when both fire.
- Most recent `focus_mode_enabled` / `focus_mode_disabled` events.
- Latest idle-snapshot context event (FocusCollector / IdleCollector emit transitions).
- Latest `intensity_aggregates` row for `intensityBars`.

Calls `YouNowStateDeriver.derive(inputs, idleThresholdSec: 300)`.

---

## 8. Test plan

### 8.1 LeafCoreTests (pure)

**`SameTaskMatcherTests.swift` — 8 cases:**

1. Empty identity → returns `[]` regardless of teammates.
2. Same LEAF-ID match → `.onSameLinearIssue`, `contextLabel = "on LEAF-204"`.
3. Same branch (both LEAF-ID nil) → `.onSameBranch`.
4. Adjacent branch (3 shared segments) → `.onAdjacentBranch`.
5. Adjacent branch threshold-fail (2 shared segments) → skipped.
6. Different repo → skipped despite branch overlap.
7. Mixed cohort sort: HIGH-confidence teammate first, then MEDIUM. Same-confidence tie broken by `lastActivityAtMs` desc, then `displayName` asc.
8. Rule 2 precondition: if my LEAF-ID is present, rule 2 cannot fire even on identical branches (rule 1 already covers — this guards against double-matching).

**`YouNowStateDeriverTests.swift` — 10 cases:**

1. `meetingActive=true` → `.inMeeting` regardless of other flags (priority test).
2. `meetingActive=false, focusActive=true, idleSec<threshold` → `.deepWorkFocus`.
3. `focusActive=true, idleSec=400` → falls through to `.away(idle)` (deep work requires recent activity).
4. `screenLocked=true` → `.away(screenLocked)`.
5. `idleSec>=300, screenLocked=false` → `.away(idle)`.
6. `frontmostAppName=Xcode, idleSec=10` → `.active(Xcode)`.
7. Custom `idleThresholdSec=60` → boundary test at 59/60.
8. Active state preserves `linearID`, `branch`, `intensityBars`.
9. Meeting state preserves all source/title/timing fields.
10. Degenerate "nothing captured" (no app, no flags, idle=0) → `.away(idle, idleSec=0)`.

**`DerivedInsightsNewMethodDefaultsTests.swift`** — mirrors existing `DerivedInsightsWorkStateDefaultsTests`. MinimalConformer struct conforms to required-only methods. Asserts the 5 new defaults: `currentTaskIdentity() == nil`, `sameTaskTeammates(.hierarchical).isEmpty`, `inboxItems(.all, nil).isEmpty`, `todayMetrics(now: now) == .empty`, `youNowState(now: now)` matches `.away(.idle)` pattern.

**`TaskIdentityTests.swift`** — `isEmpty` returns true for all-nil, false for any-non-nil. Equatable/Hashable round-trip.

**`SharedSegmentCountTests.swift`** — exercises the private split-and-count helper through `SameTaskMatcher.match` adjacent cases (Phase 8.1 keeps the helper private; tests probe via public match boundary).

### 8.2 LeafCorePrivateTests (integration with in-memory GRDB)

**`ProdInsightsCurrentTaskIdentityTests.swift`:**

1. Empty `presence_state` → returns `nil`.
2. `presence_state.derived` with branch `feature/leaf-204-substrate` → returns `TaskIdentity(linearID: "LEAF-204", branch: ...)`.
3. Branch without LEAF-ID → `linearID == nil`, branch populated.

**`ProdInsightsTodayMetricsTests.swift`:**

1. Empty DB → `.empty` (no throw).
2. Seeded events (attention + AI + commits + focus sessions) → metrics math correct: focusedMin == sum of focusSessions.durationMin, sessionsCount == count, etc.
3. Surface pills sorted desc, only non-zero surfaces present.
4. 8-cap on `surfacePills.count`.

**`ProdInsightsSameTaskTeammatesTests.swift`:**

Injects a `FakeTeammatePresenceReader` via factory swap. Verifies:

1. Stub reader (default) → returns `[]`.
2. Reader returns 3 teammates, 1 matches LEAF-ID, 1 adjacent, 1 unrelated → `match.count == 2`, sorted by confidence.
3. Reader throws → method propagates throw.

**`ProdInsightsInboxItemsTests.swift`:**

1. Empty DB → `[]`.
2. Seed `pr_review_requested` (me as reviewer) + `pr_review_comment_authored` (Anton on my PR) + open_questions (Linear) → 3 items, sorted by severity then age.
3. Filter `.reviews` → only review-kind items.
4. Search `"track-8"` → substring case-insensitive over title + sourceMeta.
5. Aggregation: 5 comments on PR #18 → 1 item with `aggregatedCount == 5`.
6. 14-day cap: events older than 14d skipped.

**`ProdInsightsYouNowStateTests.swift`:**

1. Empty DB → `.away(idle, idleSec: 0)`.
2. Active meeting event in last 5m, no exit → `.inMeeting`.
3. Focus enabled + recent activity → `.deepWorkFocus`.
4. Recent activity, no focus, no meeting → `.active`.
5. Screen lock event most recent → `.away(screenLocked)`.

### 8.3 Test fixtures

- In-memory GRDB pool via `Database.openForWrite(at:.weakDefaults, encryption:.deterministicTest)`.
- Pre-seed via raw SQL or existing migrations runner. Reuse `RelayBodyLeakageTests` harness pattern for event-writing.
- `FakeTeammatePresenceReader` defined in LeafCorePrivateTests/Insights/Fixtures/.

---

## 9. Commit decomposition (12 atomic steps)

Each step ships as one commit on `feature/phase-8-1-substrate`. After each: all tests pass, `just check-style` clean, no build warnings.

1. **`feat(phase-8-1): add Insights types — TaskIdentity, TeammateMatch, TeammateSnapshot`** — 3 new files, conformances, no behavior. Tests: Equatable/Hashable round-trip for each.
2. **`feat(phase-8-1): add Insights types — InboxItem, TodayMetrics, SurfacePill`** — 3 new files. Tests: `.empty` constants, conformances.
3. **`feat(phase-8-1): add Insights types — YouNowState + associated structs`** — 1 file with enum + 4 structs + 2 enums. Tests: enum pattern matching.
4. **`feat(phase-8-1): add TeammatePresenceReader protocol + Stub + Factory`** — 1 file. Tests: stub returns `[]`, factory returns stub when no registration.
5. **`feat(phase-8-1): add SameTaskMatcher pure func`** — 1 file + 8 tests. TDD per case (red → green per test).
6. **`feat(phase-8-1): add YouNowStateDeriver pure func`** — 1 file + 10 tests. TDD per case.
7. **`feat(phase-8-1): add DerivedInsights protocol methods + defaults`** — append 5 methods + extension defaults to `DerivedInsights.swift`. Tests: `DerivedInsightsNewMethodDefaultsTests`.
8. **`feat(phase-8-1): ProdInsights+CurrentTaskIdentity`** — 1 file + 3 integration tests.
9. **`feat(phase-8-1): ProdInsights+TodayMetrics`** — 1 file + 4 integration tests.
10. **`feat(phase-8-1): ProdInsights+SameTaskTeammates`** — 1 file + 3 integration tests (with `FakeTeammatePresenceReader`).
11. **`feat(phase-8-1): ProdInsights+InboxItems`** — 1 file + 6 integration tests (largest impl).
12. **`feat(phase-8-1): ProdInsights+YouNowState`** — 1 file + 5 integration tests.

After step 12: independent code review (Stage 6), verification (Stage 7), final commit on `.claude/shared/current-state.md` describing Phase 8.1 landed (Stage 8).

---

## 10. Risks & open questions

| ID | Concern | Mitigation |
|---|---|---|
| R-1 | `commitsToday` event_kind ambiguity — local-git-commit and `gh_push` may double-count | P1 ships broad UNION over both; cross-source dedup deferred. Plan step 9 verifies actual event_kinds in repo via grep before SQL is written. |
| R-2 | `presence_state.derived` row may not be currently composed by substrate — `derived_mode` is documented as NULL, but `state_json` content for "derived" provider may be empty too | Plan step 8 verifies. If derived row not composed, P1 reads `frontmost_app`/branch from most-recent attention events instead. Spec amended at plan stage if needed. |
| R-3 | `HomeSurface` enum lives in app target (Track-7 P1), not LeafCore — Prod query in LeafCorePrivate cannot import Track-7 surface catalog | Mirror the catalog as private const map `[surfaceKey: [event_kind]]` inside `ProdInsights+TodayMetrics.swift`. Drift risk acknowledged; resolution = move `HomeSurface` to LeafCore in Track 8 P3 (parallel to TODAY block wiring). |
| R-4 | Adjacent-branch threshold (≥ 3 segments) is hardcoded; may produce false positives on busy teams with many `feature/track-N-*` branches | Spec §11 of track design accepts this; constant kept private; v1.1 exposes setting if complaints emerge. |
| R-5 | `viewerLogin` may be missing on cold boot before first GitHub poll → "comment on my work" / "mention" filters return `[]` | Accepted. Inbox empty until first poll completes; UI shows neutral "All clear" state which is correct. |
| OQ-P1-1 | Should `currentTaskIdentity()` accept an explicit `now: Date` parameter for testability symmetry with `todayMetrics(now:)`? | Decision: no — identity is "current as of last presence write", not time-windowed. Tests inject via DB seed. |
| OQ-P1-2 | Should `YouNowInputs` itself be public (for testing from app target) or internal (only LeafCore + tests)? | Public — UI in P4 may want to construct test scenarios in SwiftUI previews. No cost to publishing. |

---

## 11. Files touched

**New (LeafCore):**

- `Packages/LeafCore/Sources/LeafCore/Insights/TaskIdentity.swift`
- `Packages/LeafCore/Sources/LeafCore/Insights/TeammateMatch.swift`
- `Packages/LeafCore/Sources/LeafCore/Insights/TeammateSnapshot.swift`
- `Packages/LeafCore/Sources/LeafCore/Insights/InboxItem.swift`
- `Packages/LeafCore/Sources/LeafCore/Insights/TodayMetrics.swift`
- `Packages/LeafCore/Sources/LeafCore/Insights/YouNowState.swift`
- `Packages/LeafCore/Sources/LeafCore/Insights/SameTaskMatcher.swift`
- `Packages/LeafCore/Sources/LeafCore/Insights/YouNowStateDeriver.swift`
- `Packages/LeafCore/Sources/LeafCore/Insights/TeammatePresenceReader.swift`

**New (LeafCorePrivate, gitignored):**

- `Packages/LeafCore/Sources/LeafCorePrivate/Prod/Insights/ProdInsights+CurrentTaskIdentity.swift`
- `Packages/LeafCore/Sources/LeafCorePrivate/Prod/Insights/ProdInsights+TodayMetrics.swift`
- `Packages/LeafCore/Sources/LeafCorePrivate/Prod/Insights/ProdInsights+SameTaskTeammates.swift`
- `Packages/LeafCore/Sources/LeafCorePrivate/Prod/Insights/ProdInsights+InboxItems.swift`
- `Packages/LeafCore/Sources/LeafCorePrivate/Prod/Insights/ProdInsights+YouNowState.swift`

**New (Tests):**

- `Packages/LeafCore/Tests/LeafCoreTests/Insights/TaskIdentityTests.swift`
- `Packages/LeafCore/Tests/LeafCoreTests/Insights/SameTaskMatcherTests.swift`
- `Packages/LeafCore/Tests/LeafCoreTests/Insights/YouNowStateDeriverTests.swift`
- `Packages/LeafCore/Tests/LeafCoreTests/Insights/DerivedInsightsNewMethodDefaultsTests.swift`
- `Packages/LeafCore/Tests/LeafCorePrivateTests/Insights/ProdInsightsCurrentTaskIdentityTests.swift`
- `Packages/LeafCore/Tests/LeafCorePrivateTests/Insights/ProdInsightsTodayMetricsTests.swift`
- `Packages/LeafCore/Tests/LeafCorePrivateTests/Insights/ProdInsightsSameTaskTeammatesTests.swift`
- `Packages/LeafCore/Tests/LeafCorePrivateTests/Insights/ProdInsightsInboxItemsTests.swift`
- `Packages/LeafCore/Tests/LeafCorePrivateTests/Insights/ProdInsightsYouNowStateTests.swift`
- `Packages/LeafCore/Tests/LeafCorePrivateTests/Insights/Fixtures/FakeTeammatePresenceReader.swift`

**Modified:**

- `Packages/LeafCore/Sources/LeafCore/Insights/DerivedInsights.swift` — append 5 protocol methods + extension defaults
- `.claude/shared/current-state.md` — final Phase 8.1 landed entry (Stage 8)

**Deleted:** none.

---

## 12. Acceptance criteria (this phase)

| AC | Description | Evidence |
|---|---|---|
| AC-1 | All 5 new public types compile + conform to Equatable/Hashable/Sendable | `swift build` green |
| AC-2 | `SameTaskMatcher` passes all 8 test cases | `swift test --filter SameTaskMatcherTests` |
| AC-3 | `YouNowStateDeriver` passes all 10 test cases | `swift test --filter YouNowStateDeriverTests` |
| AC-4 | `DerivedInsights` defaults for 5 new methods return safe values | `swift test --filter DerivedInsightsNewMethodDefaultsTests` |
| AC-5 | All 5 `ProdInsights+*` overrides pass their integration tests | `swift test --filter ProdInsights` |
| AC-6 | All 5 xcodebuild schemes Debug build SUCCESS | manual `xcodebuild` per scheme |
| AC-7 | Full SPM test suite: 0 failures, count grows by ~50-60 new tests | `swift test` from repo root |
| AC-8 | `just check-style` passes (formatting + lint, baseline clean for new files) | `just check-style` |
| AC-9 | No new event_kinds, no migrations, no ShareEventTypeKey changes | grep verification |
| AC-10 | `TeammatePresenceReader` stub default produces empty list; Phase 5.4 will register Prod reader without touching P1 API surface | code inspection |

---

## 13. References

- Track 8 design spec: `docs/superpowers/specs/2026-05-18-track-8-home-ux-design.md` (§9 P1 is the locked contract for this phase)
- Track 7 closing summary (predecessor substrate): `.claude/shared/current-state.md`
- Existing default-extension test pattern: `Packages/LeafCore/Tests/LeafCoreTests/DerivedInsightsWorkStateDefaultsTests.swift`
- Existing Prod impl pattern: `Packages/LeafCore/Sources/LeafCorePrivate/Prod/Insights/ProdInsights+RecentSessions.swift`
- Sentinel leakage test pattern (reference for P6, not P1): `Packages/LeafCore/Tests/LeafCoreTests/RelayBodyLeakageTests.swift`
- `LinearIDExtractor` (consumed in Prod impl): `Packages/LeafCore/Sources/LeafCore/Integrations/Linear/LinearIDExtractor.swift`
