# Phase 8.7 — WHERE STOPPED (P7 wire-up)

**Status:** Draft → User review gate → implementation.
**Branch:** `feature/phase-8-7-where-stopped` (off `feature/phase-8-1-substrate` `b2d1b55b`).
**Track:** Track-8 Home UX redesign.
**Substrate base:** Phase 8.1 (`WhereStoppedSnapshot` + `DerivedInsights.recentWhereStopped(limit:)` + Track-1 D3 `where_stopped_log` table).
**Target destination:** Track-7 P3 `WorkStateDetailScreen` + `RouteCoordinator.pushHomeWorkState()` (no-arg push, already shipped).
**Master spec:** `docs/superpowers/specs/2026-05-18-track-8-home-ux-design.md` §4.5.

---

## 1. Scope

P7 wires the WHERE STOPPED Home block from its Phase 8.2 placeholder shell to a populated/empty render driven by the existing Phase 8.1 substrate. Single block, no filter, no search, no sentinel-injection test, no new SQLCipher migrations, no new event_kinds, no MCP tool delta, no `ShareEventTypeKey` delta (registry frozen at 195 baseline post-Track-6).

### 1.1 Out of scope (hard exclusion)

- **Line 2 dedicated "last commit subject ≤ 4h ago"** (master spec §4.5 mockup line 2). Phase 8.1 substrate has no `recentLastCommit(maxAgeMs:)` helper; adding one requires a LeafCorePrivate SQL fetch outside this phase's wire-up contract. → Carry **C-20** to master spec §9.1 (substrate enrichment Track-9 / Phase 4.9).
- **`anchorEventId → file path:line` resolution** for mockup-style file ref ("WorkStateCard.swift:142"). `WhereStoppedSnapshot.excerpt` already prioritises commit subject → ticket title → file basename, covering most cases inline. Explicit second-pass resolution from `anchorEventId` → event row → file path is substrate gap. → Carry **C-21** Track-9.
- **WIP signals as styled chips / icons.** P7 renders `wipSignals: [String]` (when non-empty) as a single trailing caption line in `text.tertiary`. Per-signal chip / icon work → P9 polish.
- **Activity → Analytics rename** (P8). **a11y / perf audit** (P9). **AI narrative** (v1.1).

---

## 2. Architecture

Mirror P6 INBOX precedent (which mirrors P3/P4/P5):

1. **Substrate (already shipped):** `WhereStoppedSnapshot` + `DerivedInsights.recentWhereStopped(limit:)` → `[WhereStoppedSnapshot]` (returns most-recent-first per `ProdWhereStoppedDeriver`).
2. **Snapshot field (new):** `InsightsSnapshot.whereStopped: WhereStoppedSnapshot? = nil` — single optional, mirrors `workState: WorkStateSummary? = nil` Track-7 pattern. Both inits accept defaulted `nil` (zero blast radius on 23 fixture sites — same defaulted-init discipline as P3/P4/P5/P6).
3. **Reader fetch (new):** `InsightsReader.refresh()` adds 19th sequential SQL call between `inboxItems` fetch and `InsightsSnapshot` init: `let whereStopped = try insights.recentWhereStopped(limit: 1).first`.
4. **Block (rewrite):** `WhereStoppedBlock(snapshot: WhereStoppedSnapshot?)` — empty branch keeps `LeafEmptyState`; populated branch renders header + excerpt + optional wipSignals caption inside `LeafCard`. Whole-card `Button` → `RouteCoordinator.pushHomeWorkState()`.
5. **Call-site (1 line):** `HomeContent` swaps `WhereStoppedBlock()` → `WhereStoppedBlock(snapshot: snapshot.whereStopped)`.

Substrate purity: zero changes in `LeafCore/Home/WorkState/WhereStoppedSnapshot.swift` or `LeafCorePrivate/Prod/Detection/ProdWhereStoppedDeriver.swift`.

---

## 3. UI specification

### 3.1 Block layout

Full-width within Home `VStack`. Outer `VStack(alignment: .leading, spacing: LeafSpace.md)`:

1. **Section header.** `Text("WHERE YOU STOPPED")` styled with `.leafSectionLabel()` + `LeafColor.text.tertiary` foreground. When `snapshot != nil`, append ` · {age}` interpolated from `formatRelative(nowMs - snapshot.generatedAtMs)`. Empty branch: just `"WHERE YOU STOPPED"` (no age suffix — no anchor timestamp).
2. **LeafCard** (`padding: .regular`) hosting either the empty placeholder or the populated body.

Target card height: ~80pt populated, ~96pt empty (consistent with master spec §4.5).

### 3.2 Empty state (snapshot == nil)

Reuse current Phase 8.2 placeholder shape, refresh copy:

```swift
LeafEmptyState(
    icon: LeafIcons.brand.leaf,
    title: "Last work context",
    description: "No recent stop-points captured."
)
```

Icon parity with P6 INBOX empty state (`LeafIcons.brand.leaf`). No CTA (Work State detail is reachable through the Sidebar entry already; adding a duplicate CTA here would clutter the empty-state language).

### 3.3 Populated state (snapshot != nil)

`VStack(alignment: .leading, spacing: LeafSpace.sm)`:

1. **Excerpt line.** `Text(snapshot.excerpt)` with `LeafColor.text.primary` foreground, `.body` font, `.lineLimit(2)`, `.truncationMode(.tail)`. Phase 8.1 `BodyExcerptCapPrivate` already caps the excerpt at substrate boundary, no view-side cap.
2. **Optional WIP signals caption.** Rendered only when `!snapshot.wipSignals.isEmpty`:

   ```swift
   Text(snapshot.wipSignals.joined(separator: " · "))
       .font(LeafFont.body.size(.sm))
       .foregroundStyle(LeafColor.text.tertiary)
       .lineLimit(1)
       .truncationMode(.tail)
   ```

   Display order = substrate order (`commitWip` → `midEdit` → `ciFailing` per `ProdWhereStoppedDeriver`). No icons in P7; chip-styled rendering → P9 polish.

### 3.4 Tap target

Whole `LeafCard` wrapped in `Button(action: { coordinator.pushHomeWorkState() })` on populated **and** empty branches (Work State detail is meaningful in both — empty surfaces still let user open the dedicated screen for full detector history). Modifiers:

```swift
.buttonStyle(.plain)
.contentShape(Rectangle())
.accessibilityElement(children: .combine)
.accessibilityAddTraits(.isButton)
.accessibilityLabel("Open work state details")
.accessibilityHint(snapshot == nil
    ? "No recent stop-points. Opens full detector history."
    : "Opens decisions, open questions, blockers, and where-stopped history.")
```

### 3.5 Animation

`.animation(.easeInOut(duration: 0.25), value: snapshot)` applied to the inner card content. `WhereStoppedSnapshot` is already `Equatable + Hashable + Sendable` — SwiftUI's Equatable-driven re-evaluation triggers cross-fade between empty/populated and between successive populated values when generation timestamp advances.

### 3.6 Relative time helper

Reuse existing `formatRelative(_ deltaMs: Int64) -> String` from Phase 8.5 `WithYouOnThisBlock` if module-visible, else inline a copy in `WhereStoppedBlock` (carry NIT-3 from P5 review still open as helper-unification deferral → Track-9). Output buckets per Track-8 norm: `"now"` (< 60s), `"Nm ago"` (< 60min), `"Nh ago"` (< 24h), `"yesterday"`, `"N days ago"` (≤ 7d), `"on MMM d"` (otherwise — uses cached static `DateFormatter` to avoid alloc per frame per P3 carry C-4 pattern).

---

## 4. Data flow

```
SQLCipher events + where_stopped_log (M014)
        │
        ▼
ProdWhereStoppedDeriver (LeafCorePrivate moat)
        │   excerpt, wipSignals, anchorEventId, generatedAtMs
        ▼
DerivedInsights.recentWhereStopped(limit: 1) -> [WhereStoppedSnapshot]
        │
        ▼  reader takes .first
InsightsReader.refresh()   (19th sequential SQL call)
        │
        ▼
InsightsSnapshot.whereStopped: WhereStoppedSnapshot?
        │
        ▼
HomeContent(snapshot:)   →   WhereStoppedBlock(snapshot: snapshot.whereStopped)
        │
        ▼
LeafCard tap   →   RouteCoordinator.pushHomeWorkState()
        │
        ▼
NavigationStack push   →   WorkStateDetailScreen (Track-7 P3)
```

No new write paths. No event emission. No `presence_state` writes. No new MCP tools.

---

## 5. Types & call-sites

### 5.1 `InsightsSnapshot` — extend both inits

File: `Packages/LeafCore/Sources/LeafCore/Insights/InsightsSnapshot.swift`.

**Stored field** (insert after line 155 `inboxItems`):

```swift
/// Phase Track-8 P7 — WHERE STOPPED block snapshot (most recent
/// stop-point derived from Track-1 D3 `where_stopped_log` plus
/// commit / ticket / file basename heuristics in
/// `ProdWhereStoppedDeriver`). Default `nil` so existing call-sites
/// keep compiling without modification. Production
/// `InsightsReader.refresh()` writes the real value via
/// `DerivedInsights.recentWhereStopped(limit: 1).first` — `nil` when
/// substrate has no row (fresh DB, idle gate not met, or non-prod
/// `StubInsights` returning `[]`).
public let whereStopped: WhereStoppedSnapshot?
```

**Main init signature** (insert after `inboxItems: [InboxItem] = []`):

```swift
whereStopped: WhereStoppedSnapshot? = nil
```

**Main init body** (insert after `self.inboxItems = inboxItems`):

```swift
self.whereStopped = whereStopped
```

**Convenience init signature + forwarder** — same field add at matching positions.

### 5.2 `InsightsReader.refresh()` — 19th sequential SQL call

File: `Leaf/Models/InsightsReader.swift`.

Insert between current 18th call (`inboxItems`) and `InsightsSnapshot` init:

```swift
let whereStopped = try insights.recentWhereStopped(limit: 1).first
```

Pass through to `InsightsSnapshot.init(..., inboxItems: inboxItems, whereStopped: whereStopped)`.

### 5.3 `HomeView.swift` — `HomeContent` call-site

File: `Leaf/Views/Window/Home/HomeView.swift`.

Single 1-line delta in the `HomeContent` body:

```swift
- WhereStoppedBlock()
+ WhereStoppedBlock(snapshot: snapshot.whereStopped)
```

HomeView LOC budget: ≤ 280 (currently 259 post-P6 — adding 1 line → 260, well within budget).

### 5.4 `WhereStoppedBlock` rewrite

File: `Leaf/Views/Window/Home/Blocks/WhereStoppedBlock.swift`.

Full rewrite from 27-line placeholder → ~80-line populated/empty block. Stored property `let snapshot: WhereStoppedSnapshot?`. Inject `@Environment(RouteCoordinator.self) private var coordinator` (matches `TodayBlock.swift:17` precedent — `RouteCoordinator` is `@Observable`, so use the `@Environment` macro, not `@EnvironmentObject`).

Helper functions (file-local, `private`):

- `private var headerText: String` — `"WHERE YOU STOPPED" + (snapshot.map { " · \(formatRelative(...))"} ?? "")`
- `private func formatRelative(_ deltaMs: Int64) -> String` — buckets per §3.6 (or call shared if extracted later)
- `private var accessibilityHint: String` — per §3.4

---

## 6. Carry-overs to master spec §9.1

Append at end of §9.1 P9 carry-over backlog (after C-19):

- **C-20 WHERE STOPPED Line 2 dedicated last-commit subject (P7 carry).** Master spec §4.5 mockup specifies a 2-line populated body: Line 1 = excerpt + file ref, Line 2 = "last commit subject (60 char cap) if commit ≤ 4h ago". Phase 8.1 substrate `WhereStoppedSnapshot.excerpt` already prioritises commit subject when commit-based, covering Line 1 inline for the common case. Dedicated Line 2 requires a separate SQL helper (`recentLastCommit(maxAgeMs:)`) on `DerivedInsights` plus a `LeafCorePrivate` query against `events WHERE event_kind = 'git_commit' AND timestamp >= now - 4h ORDER BY timestamp DESC LIMIT 1`. Resolution = substrate extension in Track-9 / Phase 4.9. Until then, populated render falls back to single-line `excerpt`. File: `Packages/LeafCore/Sources/LeafCore/Insights/DerivedInsights.swift`.
- **C-21 WHERE STOPPED `anchorEventId → file path:line` resolution (P7 carry).** Master spec §4.5 mockup illustrates "Track-7 P5 polish · WorkStateCard.swift:142" — a hybrid label combining excerpt with the source event's file path and line number. Current `WhereStoppedSnapshot.anchorEventId: Int64?` carries only the event id; resolving to a path:line pair requires a second-pass lookup against `events.payload_json` (extract file_path) and line-number capture in the originating collector (Layer A AX or FSEvents — not currently retained in payload). Substrate enrichment pair: (a) add file_path+line to `events` payload allow-list for relevant kinds, (b) add `WhereStoppedSnapshot.anchorFilePath: String?` + `.anchorLine: Int?` fields. Resolution = Track-9 substrate sweep paired with C-20 backend fetch. File: `Packages/LeafCorePrivate/Prod/Detection/ProdWhereStoppedDeriver.swift`.

---

## 7. Privacy walkback audit

### 7.1 No new payload surface

WHERE STOPPED block reads pre-derived `WhereStoppedSnapshot` fields only. `ProdWhereStoppedDeriver` already applies `BodyExcerptCapPrivate` and the ADR-010 allow-list at the substrate boundary; the block is a read-only render of pre-walked content. No raw event payload, no comment body, no email subject, no full file content, no prompt text reaches the view layer.

Fields surfaced in render:

- `excerpt: String` (length-capped at substrate, ADR-010 walked)
- `wipSignals: [String]` (small enum-like markers `commitWip` / `midEdit`; no free text from user content)
- `generatedAtMs: Int64` (timestamp, opaque)
- `anchorEventId: Int64?` (opaque row id; not surfaced in UI text, used only for future C-21 resolution — currently unused in P7)

### 7.2 No sentinel-injection test required

Pattern parity:

- **P3 / P4 / P5** — derived metrics / state enums / opaque IDs only → no sentinel needed.
- **P6** — INBOX item titles carry untyped strings derived from Layer B / D3 contexts where comment bodies could leak. Sentinel test (`testEventBodyDoesNotLeakIntoPresenceState_INBOX` with `LEAKED_SENTINEL_INBOX_BODY`) was mandated by master spec §7.
- **P7** — WHERE STOPPED block reads only `WhereStoppedSnapshot.excerpt` which `ProdWhereStoppedDeriver` already constructs from already-walked sources (commit subject from `git_commit` payload, ticket title from `linear_issue_*` payload, file basename from `xcode_active_doc_changed` payload — all three already pass walkback). No new untyped string surface in P7. → No sentinel-injection test added.

If future Track-9 enrichment (C-20 / C-21) introduces new fields, a sentinel test for those fields will land in that phase.

### 7.3 Grep verification (CI gate)

```bash
grep -nE "absolute_path|full_comment_body|raw_email|notes_body|prompt|tool_input|response_body|email_subject|note_body|file_contents|thinking|content" \
    Leaf/Views/Window/Home/Blocks/WhereStoppedBlock.swift \
    Leaf/Views/Window/Home/HomeView.swift \
    Packages/LeafCore/Sources/LeafCore/Insights/InsightsSnapshot.swift \
    Leaf/Models/InsightsReader.swift
```

Expected: 0 hits. AC-9 in §12 below.

---

## 8. Testing strategy

### 8.1 Phase 8.1 substrate tests (no changes)

`WhereStoppedSnapshot` round-trip tests, `WhereStoppedDeriverTests`, `ProdWhereStoppedDeriverTests` — all unchanged.

### 8.2 Phase 8.7 new tests

**Round-trip on `InsightsSnapshot.whereStopped`** (LeafCoreTests/InsightsSnapshotTests.swift):

1. `testInit_DefaultedWhereStoppedIsNil` — main init without `whereStopped` arg → field is `nil`.
2. `testInit_RoundTripWhereStopped` — pass non-nil `WhereStoppedSnapshot(...)` → field round-trips intact, `Equatable` holds.

Optional 3rd: `testConvenienceInit_DefaultedWhereStoppedIsNil` — convenience init also `nil` by default.

### 8.3 Test count delta

Baseline post-P6: 2776 XCTest + 45 Swift-Testing = 2821 total.
Phase 8.7: +2 to +3 XCTest. Target: **2778-2779 XCTest** + 45 Swift-Testing = 2823-2824 total, 0 failures, 4 skipped.

---

## 9. Manual smoke (AC §10 from master spec)

Not blocking ship — Phase 8.4 / 8.5 / 8.6 manual smoke deferred to Track-8 wrap.

Spot checks during T4:

1. **Empty render** (StubInsights / fresh DB) — block renders header `"WHERE YOU STOPPED"` (no age suffix) + `LeafEmptyState` with refreshed copy. Card is tappable, opens `WorkStateDetailScreen`.
2. **Populated render** (ProdInsights with seeded `where_stopped_log` row) — block renders header `"WHERE YOU STOPPED · 12m ago"` + excerpt + optional wipSignals caption. Card tap opens `WorkStateDetailScreen`.
3. **Animation** — toggling between empty and populated states triggers 250ms cross-fade.

---

## 10. Build & verification

| Gate | Command | Pass criterion |
|---|---|---|
| Token fidelity | `just check-tokens` | 3-tier clean (BASE + MIGRATION + RETIRED) |
| Build matrix | `xcodebuild -scheme Leaf -configuration Debug build` × 5 schemes | 5/5 SUCCESS |
| Test suite | `swift test` | 0 failures, ≥ 2778 XCTest + 45 Swift-Testing |
| Privacy walkback | grep block per §7.3 | 0 hits |
| LOC budget | `wc -l Leaf/Views/Window/Home/HomeView.swift` | ≤ 280 (target ≤ 261) |

---

## 11. Plan structure (Stage 4 input)

Five atomic commits, TDD discipline (test first → run → see fail → implement → run → see pass → commit). See `.claude/plans/phase-8-7.md` for tactical step-by-step.

1. **T1** — `feat(phase-8-7): InsightsSnapshot.whereStopped defaulted field`. TDD red → green: 2 round-trip tests + field add to both inits + Equatable/Hashable parity.
2. **T2** — `feat(phase-8-7): InsightsReader 19th SQL call for whereStopped`. Add fetch + thread into snapshot init.
3. **T3** — `feat(phase-8-7): WhereStoppedBlock(snapshot:) shell + HomeContent call-site`. Block accepts `snapshot:` param, empty branch reuses `LeafEmptyState` (updated copy), populated branch is `EmptyView()` placeholder for T4 to fill. HomeContent 1-line call-site swap.
4. **T4** — `feat(phase-8-7): WhereStoppedBlock populated body + tap routing + animation`. Header age suffix, excerpt + wipSignals caption, full-card Button → `pushHomeWorkState()`, 250ms easeInOut animation, a11y traits.
5. **T5** — `feat(phase-8-7): master spec §9.1 carry-overs C-20..C-21 + final verification`. Append C-20 / C-21 to master spec §9.1. Run all gates from §10. Update `.claude/shared/current-state.md` with landing summary (Stage 8 ship commit, separate).

---

## 12. Acceptance summary

| AC | Check |
|---|---|
| AC-1 | `InsightsSnapshot.whereStopped: WhereStoppedSnapshot?` field exists on struct, both inits, defaulted `nil` |
| AC-2 | `InsightsReader.refresh()` includes 19th sequential SQL call `try insights.recentWhereStopped(limit: 1).first` |
| AC-3 | `WhereStoppedBlock` accepts `snapshot: WhereStoppedSnapshot?` constructor arg |
| AC-4 | Empty branch renders updated copy "No recent stop-points captured." inside `LeafEmptyState`, no CTA |
| AC-5 | Populated branch renders header `"WHERE YOU STOPPED · {age}"`, excerpt with `text.primary` 2-line cap, optional wipSignals caption |
| AC-6 | Whole-card `Button` → `coordinator.pushHomeWorkState()` on empty AND populated; `.accessibilityAddTraits(.isButton)` applied |
| AC-7 | `.animation(.easeInOut(duration: 0.25), value: snapshot)` triggers cross-fade |
| AC-8 | Master spec §9.1 appended C-20 + C-21 entries |
| AC-9 | Privacy walkback grep (§7.3) returns 0 hits |
| AC-10 | `just check-tokens` clean across 3 tiers |
| AC-11 | All 5 xcodebuild schemes Debug build SUCCESS |
| AC-12 | `swift test` 0 failures, +2-3 new XCTest |
| AC-13 | No new SQLCipher migrations (verify `git diff feature/phase-8-1-substrate -- Packages/LeafCore/Sources/LeafCore/DB/` empty) |
| AC-14 | No new event_kinds (verify `git diff feature/phase-8-1-substrate -- Packages/LeafCore/Sources/LeafCore/Privacy/ShareEventTypeKey.swift` empty) |
| AC-15 | No new MCP tools (verify `git diff feature/phase-8-1-substrate -- Packages/LeafCore/Sources/LeafCore/MCP/` empty) |
| AC-16 | HomeView.swift ≤ 280 LOC |

---

## 13. Open questions

1. **Helper unification** — `formatRelative` may already exist in `WithYouOnThisBlock` (P5). Decision deferred to T4: if module-visible, reuse; else inline copy + carry helper-unification deferral to Track-9 (consistent with C-19 / NIT-3 from P5 review).
2. **wipSignals enum vs string** — P7 reads `wipSignals: [String]` as-is. Future Track-9 may model as typed enum (`enum WipSignal { case commitWip, midEdit, ciFailing }`). Out of P7 scope; current `String` array suffices for caption render.
