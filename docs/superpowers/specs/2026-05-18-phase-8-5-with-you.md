# Phase 8.5 — WITH YOU ON THIS (P5 wire-up)

**Track:** Track-8 (Home as Operational Console)
**Phase:** 5 of 9 (P5)
**Date:** 2026-05-18
**Branch:** `feature/phase-8-5-with-you` off `feature/phase-8-1-substrate` @ `ff09a3aa`
**Master spec:** `docs/superpowers/specs/2026-05-18-track-8-home-ux-design.md` §4.3, §6.2, §6.3, §8.4, §9 P5, §10 AC-5 / AC-6
**Substrate spec:** `docs/superpowers/specs/2026-05-18-phase-8-1-substrate.md`
**Predecessor (pattern source):** `docs/superpowers/specs/2026-05-18-phase-8-4-you-now.md`

---

## 1. Scope

Pure UI surface wire-up: route `DerivedInsights.sameTaskTeammates(rule:)` substrate (shipped Phase 8.1) through `InsightsSnapshot` and `InsightsReader.refresh()` into the existing `WithYouOnThisBlock` placeholder shell (created Phase 8.2). Master spec §4.3 layout — up to 5 teammate rows + confidence badges + empty state Team CTA + overflow footer.

**Substrate landed in Phase 8.1, no changes:**

- `DerivedInsights.sameTaskTeammates(rule:) throws -> [TeammateMatch]` (default `[]`).
- `TeammateMatch { memberID, displayName, currentApp, durationSec, confidence, contextLabel, lastActivityAtMs }`.
- `MatchConfidence { onSameLinearIssue, onSameBranch, onAdjacentBranch }` with `sortRank` 0/1/2.
- `SameTaskMatcher.match(myIdentity:teammates:rule:)` — hierarchical 3-rule chain; output sorted (confidence asc → `lastActivityAtMs` desc → `displayName` asc).
- `TeammatePresenceReader` (protocol + `StubTeammatePresenceReader` + factory); real DB-backed reader = Phase 5.4 (`presence_history` table not migrated yet).
- `ProdInsights+SameTaskTeammates.swift` — 10-minute freshness window; identity-first short-circuit.
- `ProdInsights+CurrentTaskIdentity.swift` — branch + LEAF-NN extracted from most-recent `attention` event's `window_title`.

**Hard exclusions (out of scope):**

- ❌ Offline / "Team data stale" footer (P9 / Phase 5.6 carry — needs relay status field on `InsightsSnapshot`).
- ❌ "N active elsewhere" count in empty-state CTA (P5 carry — needs `totalActiveTeammates` deriver or teammate-list plumbing through view, both Phase 5.4 territory).
- ❌ Per-teammate detail screen on Team tab (Track-9 / separate feature).
- ❌ `RouteCoordinator.pushTeam(memberID:)` (Track-9).
- ❌ Substrate fix for `TeammateMatch.durationSec` hardcoded 0 (Phase 5.4 / Track-9 enrichment).
- ❌ YOU·NOW substrate enrichment (Track-9 — Phase 8.4 carry).
- ❌ INBOX / WHERE STOPPED wire-up (P6 / P7).

---

## 2. Architecture

Substrate already complete. P5 adds three thin layers:

1. **`InsightsSnapshot.sameTaskTeammates`** — new field, defaulted `[]` in both inits.
2. **`InsightsReader.refresh()`** — one new sequential `try insights.sameTaskTeammates(rule: .hierarchical)` call between `youNowState` fetch and `InsightsSnapshot` construction.
3. **`WithYouOnThisBlock(matches: [TeammateMatch])`** — body rewrite from placeholder `LeafEmptyState` to 5-row list + empty state + overflow footer + Team-tab routing.

`HomeContent` in `HomeView.swift` adjusts one call-site: `WithYouOnThisBlock()` → `WithYouOnThisBlock(matches: snapshot.sameTaskTeammates)`.

---

## 3. UI specification

### 3.1 Layout (mirror P4 YouNowBlock pattern)

```
VStack(alignment: .leading, spacing: LeafSpace.md) {
  Text("WITH YOU ON THIS").leafSectionLabel().foregroundStyle(LeafColor.text.tertiary)

  LeafCard(padding: .regular) {
    if matches.isEmpty {
      <empty state>
    } else {
      VStack(alignment: .leading, spacing: LeafSpace.sm) {
        ForEach(matches.prefix(5)) { match in
          <teammate row, tappable>
        }
        if matches.count > 5 {
          <overflow footer>
        }
      }
    }
  }
}
```

No tone-border overlay (P4 had per-state tint; here rows are heterogeneous and the section itself carries no state colour).

### 3.2 Teammate row

`HStack(alignment: .center, spacing: LeafSpace.md)`:

1. **Avatar** — initials circle, 32×32, deterministic tint hash of `memberID`. `Text(initials).font(LeafType.body.small).foregroundStyle(.white)` inside `Circle().fill(avatarTint)`.
2. **VStack** (leading, `LeafSpace.xxs`):
   - Line 1: `match.displayName`, `LeafType.title.small`, `LeafColor.text.primary`, `.lineLimit(1)`.
   - Line 2: `match.currentApp ?? "—"` + " · " + `formatRelative(msAgo: match.lastActivityAtMs)`, `LeafType.body.small`, `LeafColor.text.secondary`, `.lineLimit(1)`.
3. **Spacer**.
4. **Confidence badge** — `LeafIconChip` is icon-shaped; instead use a custom `LeafBadge`-style pill `Text(match.contextLabel).font(LeafType.body.small).foregroundStyle(badgeTint).padding(.horizontal, LeafSpace.sm).padding(.vertical, LeafSpace.xxs).background(RoundedRectangle(cornerRadius: LeafRadius.sm).fill(badgeTint.opacity(0.15)))`.

Whole row wrapped in `Button(action: { handleTap() }) { … }` `.buttonStyle(.plain)`, with `.accessibilityLabel("\(displayName), \(contextLabel), tap to open Team tab")` + `.accessibilityAddTraits(.isButton)`.

`handleTap()`: `windowState.section = .team`.

### 3.3 Confidence tint resolution

| `MatchConfidence` | Badge tint |
| --- | --- |
| `.onSameLinearIssue` | `LeafColor.status.success` (green) |
| `.onSameBranch` | `LeafColor.status.success` (green) |
| `.onAdjacentBranch` | `LeafColor.status.warning` (amber) |

Spec §4.3 distinguishes HIGH (both green) vs MEDIUM (amber). No separate visual distinction between `onSameLinearIssue` and `onSameBranch` — both render same green, the badge **text** (`contextLabel`) distinguishes ("on LEAF-204" vs "same branch").

### 3.4 Empty state

`LeafEmptyState(icon: LeafIcons.brand.leaf, title: "No one's on this task right now.", description: "Teammates working on the same Linear issue, branch, or adjacent branch will appear here.", ctaTitle: "→ Team", onCTA: { windowState.section = .team })`.

CTA does not include "(N active elsewhere)" count — substrate gap, see §6 carry-over C-10.

### 3.5 Overflow footer

`if matches.count > 5`:

```swift
Button {
  windowState.section = .team
} label: {
  Text("→ +\(matches.count - 5) more on this task")
    .font(LeafType.body.small)
    .foregroundStyle(LeafColor.accent.primary)
}
.buttonStyle(.plain)
.accessibilityLabel("Show \(matches.count - 5) more teammates in Team tab")
.accessibilityAddTraits(.isButton)
.padding(.top, LeafSpace.xs)
```

### 3.6 Avatar tint hash

Deterministic per `memberID`:

```swift
private func avatarTint(forMemberID id: String) -> Color {
    let palette: [Color] = [
        LeafColor.accent.primary,
        LeafColor.status.info,
        LeafColor.status.warning,
        LeafColor.status.success,
        LeafColor.text.secondary,
    ]
    let hash = abs(id.hashValue)
    return palette[hash % palette.count]
}
```

`Color` is not `Hashable` collateral — using Swift's built-in `String.hashValue`. Per-launch deterministic; cross-launch may drift (Swift hash randomization). Acceptable: avatars are visual aid, not identity. P9 carry if it bothers: switch to FNV-1a or `SHA256(memberID).first` byte modulo.

### 3.7 Initials helper

```swift
private func initials(_ displayName: String) -> String {
    let parts = displayName.split(separator: " ").prefix(2)
    let chars = parts.compactMap { $0.first.map(String.init) }
    let joined = chars.joined().uppercased()
    return joined.isEmpty ? "?" : String(joined.prefix(2))
}
```

Examples: "Dmitrii Demidov" → "DD", "Anton" → "A", "" → "?".

### 3.8 Relative time helper

Already exists in `YouNowBlock` (`formatRelative(msAgo:)`) — same logic: `(now_ms - last_ms) / 1000` → `formatDuration` + " ago". Phase 8.5 keeps it block-private (mirror Phase 8.4 — extracted later if 3rd caller appears).

### 3.9 Animation

`.animation(.easeInOut(duration: 0.25), value: matches)` on the inner `VStack` for row in/out transitions when matches set changes.

---

## 4. Data flow

```text
Phase 5.4 (future)             ← presence_history reads
       ↓
DBTeammatePresenceReader        ← Phase 5.4 register at Agent startup
       ↓ (P5 today: StubTeammatePresenceReader returns [])
ProdInsights.sameTaskTeammates(rule: .hierarchical)
       ↓
InsightsReader.refresh() — 17th sequential SQL call between youNowState and snapshot init
       ↓
InsightsSnapshot.sameTaskTeammates: [TeammateMatch]
       ↓
HomeContent → WithYouOnThisBlock(matches: snapshot.sameTaskTeammates)
       ↓
View renders empty state (P5 reality with stub reader) or 5-row list (Phase 5.4 onward)
```

---

## 5. Types & call-sites

### 5.1 `InsightsSnapshot` (extend both inits — P3/P4 pattern)

```swift
// public init
public let sameTaskTeammates: [TeammateMatch]

// in both init signatures (public + convenience):
sameTaskTeammates: [TeammateMatch] = []

// assignment:
self.sameTaskTeammates = sameTaskTeammates

// convenience init forwards to public init's sameTaskTeammates param.
```

Defaulted argument → zero blast radius on existing fixture sites (mirror P3 todayMetrics + P4 youNowState — verified Phase 8.4 `InsightsSnapshotTests` not modified).

### 5.2 `InsightsReader.refresh()` — new fetch line

```swift
// After existing youNowState fetch (line 162):
let youNowState = try insights.youNowState(now: Date())
try Task.checkCancellation()

// Track-8 Phase 8.5 — same-task teammates list. Hierarchical rule
// (same Linear → same branch → adjacent branch). Stub reader returns
// [] until Phase 5.4 wires DBTeammatePresenceReader against
// presence_history; block renders empty state until then.
let sameTaskTeammates = try insights.sameTaskTeammates(rule: .hierarchical)
try Task.checkCancellation()
```

Pass to `InsightsSnapshot(...)` init as `sameTaskTeammates: sameTaskTeammates`.

### 5.3 `HomeView.swift` — `HomeContent` call-site

```swift
// Before
WithYouOnThisBlock()
  .frame(maxWidth: .infinity)

// After
WithYouOnThisBlock(matches: snapshot.sameTaskTeammates)
  .frame(maxWidth: .infinity)
```

No other `HomeView.swift` changes.

### 5.4 `WithYouOnThisBlock` rewrite (~150 LOC)

Single-file rewrite. Imports `LeafCore` (for `TeammateMatch`, `MatchConfidence`) and `SwiftUI`. Reads `WindowState` from environment for Team-tab routing.

```swift
struct WithYouOnThisBlock: View {
    let matches: [TeammateMatch]
    @Environment(WindowState.self) private var windowState

    private static let rowCap = 5

    var body: some View { /* §3.1 layout */ }
    private func teammateRow(_ match: TeammateMatch) -> some View { /* §3.2 */ }
    private func confidenceTint(_ c: MatchConfidence) -> Color { /* §3.3 */ }
    private func emptyState() -> some View { /* §3.4 */ }
    private func overflowFooter(remaining: Int) -> some View { /* §3.5 */ }
    private func avatarTint(forMemberID id: String) -> Color { /* §3.6 */ }
    private func initials(_ displayName: String) -> String { /* §3.7 */ }
    private func formatRelative(msAgo ms: Int64) -> String { /* §3.8 */ }
}
```

### 5.5 `TeammateMatch: Identifiable` — verify

`TeammateMatch` is `Equatable, Hashable, Sendable` — but `Identifiable` is not declared on the type. `ForEach` will need an explicit `id: \.memberID` projection. No type change in `LeafCore`.

---

## 6. Carry-overs to master spec §9.1

Append at end of master spec §9.1:

- **C-10 WithYouOnThisBlock empty-state CTA missing N count.** Spec §4.3 calls for "→ Team (N active elsewhere)" where N = teammates active anywhere who don't match my task. P5 ships CTA as "→ Team" without count. Resolution requires either (a) new `totalActiveTeammates` deriver, or (b) plumbing teammate list through `InsightsSnapshot` (privacy surface expansion — list of all teammates, not just matches). Phase 5.4 enrichment. File: `Leaf/Views/Window/Home/Blocks/WithYouOnThisBlock.swift:emptyState`.
- **C-11 WithYouOnThisBlock offline / stale footer absent.** Spec §4.3 calls for muted footer "Team data stale ({lastSync} ago). Reconnecting…" when relay disconnected OR last `presence_history` sync > 10 min. No relay status signal in `InsightsSnapshot` today. P9 / Phase 5.6 carry — pairs with relay status plumbing. File: `WithYouOnThisBlock.swift`.
- **C-12 Row tap routes to Team tab without teammate selection.** Spec §4.3 "Click row → opens teammate detail in Team tab" — Team tab has no per-teammate detail screen. P5 ships row tap as `windowState.section = .team`. Resolution = Team-tab teammate detail screen + `RouteCoordinator.pushTeam(memberID:)`. Track-9 / separate feature.
- **C-13 TeammateMatch.durationSec hardcoded 0 in substrate.** `SameTaskMatcher.makeMatch` (line 73 of `SameTaskMatcher.swift`) sets `durationSec: 0` unconditionally. UI does not surface a "duration on task" field today (row line 2 uses `lastActivityAtMs` "ago" relative time). Substrate enrichment (compute duration from earliest task-matching snapshot per teammate) is Phase 5.4 / Track-9. No UI change required when substrate fixes.

---

## 7. Privacy walkback audit

No new privacy surface:

- `TeammateMatch.memberID` — opaque ID per ADR-014 symmetric model.
- `TeammateMatch.displayName` — member-controlled, broadcast field.
- `TeammateMatch.currentApp` — already broadcast filtered by Share Controls (ADR-020) before reaching relay.
- `TeammateMatch.contextLabel` — derived ("on LEAF-204" / "same branch" / "adjacent branch"). Branch names + LEAF-NN already in shipped payloads.
- `TeammateMatch.confidence` — local enum.
- `TeammateMatch.lastActivityAtMs` — timestamp, not content.

**Verification:** `grep -nE "absolute_path|full_comment_body|raw_email|notes_body|prompt|tool_input|response_body|email_subject|note_body" Leaf/Views/Window/Home/Blocks/WithYouOnThisBlock.swift` expected 0 hits.

---

## 8. Testing strategy

### 8.1 Phase 8.1 substrate tests (already shipped, no changes)

- `LeafCoreTests/Insights/SameTaskMatcherTests.swift` — hierarchical rule + sort verification.
- `LeafCoreTests/Insights/TaskIdentityTests.swift`.
- `LeafCorePrivateTests/Insights/ProdInsightsSameTaskTeammatesTests.swift`.
- `LeafCorePrivateTests/Insights/ProdInsightsCurrentTaskIdentityTests.swift`.

### 8.2 Phase 8.5 new tests

**`InsightsSnapshotTests.swift`** — append one micro-test verifying defaulted-init still compiles existing call-sites + `sameTaskTeammates` defaults to `[]`:

```swift
func testSnapshotDefaultsSameTaskTeammatesEmpty() {
    let snap = InsightsSnapshot(topApps: [], sessions: [], switchRate: 0, deepSessionMinSec: 60)
    XCTAssertEqual(snap.sameTaskTeammates, [])
}
```

**Skip view-level snapshot tests** — `WithYouOnThisBlock` is pure presentation over typed substrate. Coverage gain low vs maintenance cost. Manual smoke (§9) covers UI fidelity.

### 8.3 Test counts

- Baseline (Phase 8.4 ship): **2771 XCTest + 45 Swift-Testing = 2816 total**, 4 skipped.
- Phase 8.5: +1 XCTest in `InsightsSnapshotTests`.
- Target: **2772 XCTest + 45 Swift-Testing = 2817 total**, 4 skipped, 0 failures.

---

## 9. Manual smoke (AC §10 from master spec)

P5 cannot fully exercise master AC-5 / AC-6 (which require live teammate on second Mac via Phase 5.4 reader). P5 smoke covers UI fidelity only:

| AC | Description | Expected |
| --- | --- | --- |
| **P5-A** | Open Leaf with `sameTaskTeammates == []` (stub reader reality) | Empty state renders: "No one's on this task right now." + "→ Team" CTA |
| **P5-B** | Tap "→ Team" CTA in empty state | Sidebar switches to Team tab (`windowState.section = .team`) |
| **P5-C** | (Synthetic — feed `WithYouOnThisBlock` 3 matches via SwiftUI preview or temporary debug injection) | Renders 3 rows: avatar + name + "app · Xs ago" + tinted badge with `contextLabel` |
| **P5-D** | (Synthetic — feed 7 matches) | 5 rows + "→ +2 more on this task" footer |
| **P5-E** | Tap a teammate row | Sidebar switches to Team tab |
| **P5-F** | Privacy walkback grep | 0 hits forbidden fields in `WithYouOnThisBlock.swift` |

Master AC-5 (adjacent-branch badge) + AC-6 (same-branch promotion) deferred to Phase 5.4 two-Mac smoke. Tracked in current-state.md under "Following Track-8 P9 acceptance".

---

## 10. Build & verification

- **All 5 xcodebuild schemes** Debug build SUCCESS (LeafCore / LeafCorePrivate / Leaf / LeafAgent / LeafMCP).
- **SPM `swift test`:** **2817 total** (+1 vs Phase 8.4 baseline), 0 failures, 4 skipped.
- **`just check-tokens`** — 3-tier clean (BASE + MIGRATION + RETIRED).
- **`just check-style`** — swift-format + SwiftLint report-only (Phase 1 baseline; Phase 2 cleanup ongoing).
- **Privacy walkback** — `grep` on `WithYouOnThisBlock.swift` returns 0 forbidden-field hits.
- **HomeView.swift LOC** — unchanged structure (single call-site swap). `WithYouOnThisBlock.swift` ~150 LOC (≤ 200 LOC, P4 was 336).

---

## 11. Plan structure (Stage 4 input)

Roughly 6 atomic commits, sequential TDD:

1. **T1** — `InsightsSnapshot.sameTaskTeammates: [TeammateMatch]` field + defaulted-init in both signatures + assignment. Test: `testSnapshotDefaultsSameTaskTeammatesEmpty`. Red → green.
2. **T2** — `InsightsReader.refresh()` adds `sameTaskTeammates` fetch + threads to snapshot init. No new test (covered by existing reader tests which already pass through defaulted snapshot).
3. **T3** — `WithYouOnThisBlock(matches:)` API rewrite: param + empty-state branch only (preserve placeholder shape, just add `matches` param + render `LeafEmptyState` w/ Team CTA). `HomeContent` call-site swap.
4. **T4** — `WithYouOnThisBlock` row rendering: `teammateRow` + helpers (`avatarTint`, `initials`, `formatRelative`, `confidenceTint`). 5-row cap via `prefix(5)`.
5. **T5** — Overflow footer (`+N more`).
6. **T6** — Polish: animation, a11y labels, privacy walkback grep, manual smoke verification.

---

## 12. Acceptance summary

| Item | Pass criterion |
| --- | --- |
| AC-1 | Substrate untouched (no `LeafCore/Insights/` changes; verified via `git diff --stat Packages/LeafCore/Sources/LeafCore/Insights/`) |
| AC-2 | Zero new SQLCipher migrations / event_kinds / MCP tools / ShareEventTypeKey delta |
| AC-3 | `sameTaskTeammates: [TeammateMatch] = []` defaulted in both `InsightsSnapshot` inits |
| AC-4 | `InsightsReader.refresh()` invokes `sameTaskTeammates(rule: .hierarchical)` once per refresh |
| AC-5 | `WithYouOnThisBlock(matches:)` renders empty state when `[]`, rows when populated, overflow footer when > 5 |
| AC-6 | Each row tappable; tap routes `windowState.section = .team` |
| AC-7 | Confidence badge tint matches §3.3 |
| AC-8 | All 5 xcodebuild schemes Debug SUCCESS |
| AC-9 | `swift test` 2817 total, 0 failures, 4 skipped |
| AC-10 | `just check-tokens` 3-tier clean |
| AC-11 | Privacy walkback grep on `WithYouOnThisBlock.swift` → 0 hits |
| AC-12 | HomeView.swift unchanged outside the single call-site swap |
| AC-13 | Carry-overs C-10..C-13 appended to master spec §9.1 |

---

## 13. Open questions

None. Master spec §4.3 design locked; substrate frozen at Phase 8.1; OQ resolution documented in §6 carry-overs (deferred items) and §3 (resolved items).
