# Track 7 — P2-collapsed · Capture Surfaces (Xcode + IDEs + Browsers + Zoom + Calendar) · Design Spec

**Status:** Draft (2026-05-18). Promoted to "Active" after user review gate (Stage 3) closes.
**Stage 0 discovery:** parallel Explore agents — events schema + DerivedInsights API + UI inventory (in-session, 2026-05-18).
**Stage 1 reference:** P1 spec `2026-05-17-track-7-ui-surface-polish-design.md` (§4 SurfaceCard contract, §5 SurfaceDetailLayout contract, §9 DerivedInsights coupling).
**Authors:** Alex + Claude.

---

## 1. Goal & scope

Promote 5 capture surfaces (Xcode / IDEs / Browsers / Zoom / Google Calendar) from "compact disabled rows on Home + placeholder detail screen" to **fully-wired Home cards + drill-down detail screens reusing the P1 template byte-for-byte**. Inherits all P1 invariants (zero new event_kinds / migrations / MCP tools; ADR-010 walkback discipline; default-OFF posture; D1-token-only UI).

Fitness function for the phase:

1. **Template fidelity.** Every surface uses `SurfaceCard<Spark>` + `SurfaceDetailLayout<Aggregates, Chart>` from P1. Zero new component types in `Leaf/Theme/` or `Packages/LeafCore/`. Zero new tokens. `just check-tokens` passes.
2. **Substrate-only coupling.** Track-6 P2–P6 event_kinds (already in DB, gated default OFF in `ShareEventTypeKey`) become readable through new typed `DerivedInsights` methods. No new event_kinds. No new migrations. No new MCP tools. No new schema columns.
3. **Privacy walkback preserved.** New view code renders only aggregates / buckets / structured metadata that already passes ADR-010 walkback. No raw body field reads. `RelayBodyLeakageTests` continues to pass; a per-surface grep fence rules out forbidden field references in new code.
4. **Default OFF posture intact.** Card renders compact disabled row + `[Enable]` CTA when the surface's enable-state store says OFF (Step 2 tactical fix already locked the lookup). Enabling promotes to full card within ≤1 redraw cycle.
5. **5 acceptance smokes pass.** Per-surface A–G smoke on the author's Mac (spec §13.1 from P1 wave) on real data — Xcode build / VSCode workspace switch / Safari 3-tab nav / Zoom meeting join+leave / OAuth connect.

**In scope:** 5 surface card view-models, 5 detail-screen view-models, 5 detail screens, 5 `XxxCardPayload` structs, 5 `XxxActivityBreakdown` return types, 5 new `DerivedInsights` protocol methods (+ default = `.empty` extensions + StubInsights overrides + LeafCorePrivate ProdInsights implementations), Settings sub-anchor IDs for in-section deep-link, `WindowSettingsView.applyPendingTarget` extension to chain to `sub` anchor.

**Out of scope (hard exclusion list, mirrors P1 §1 + carve-outs):**

- New event_kinds, migrations, MCP tools, schema columns, ShareEventTypeKey registry additions.
- Calendar detail-screen rich aggregates — Calendar surface ships card-only with "Captured · Waiting for events" headline until P11 (GCP gate, see §6).
- Bumping Calendar / Zoom default OFF posture to ON. Posture stays OFF.
- New token primitives, new tokens, new composites, new layouts. Pure consumer of P1's `SurfaceCard` / `SurfaceRow` / `SurfaceDetailLayout` + D1 token set.
- AI-narrative / "describe the surface in words" — same v1.1 BYOK track as P1.
- Cross-surface aggregates ("Xcode + IDEs combined coding time") — separate dimension, not Track 7 scope.
- New per-surface settings UI — Settings sub-section toggles already shipped in Track-6.
- Modifying any `Insights/Parsers/` or `Collectors/` code. Substrate is frozen for this phase.
- Plugin work for IDEs (per-edit / debugger / terminal / extension list) — Layer D V2, separate track.
- Cross-provider linking visualizations (LinearIDExtractor, event_links) — handled in P7 Work State.
- LivePresenceWidget click-through (Linear / GitHub / Slack drill-downs) — P8-collapsed.

---

## 2. Decisions locked (brainstorm carry-over)

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **Per-surface view-model pattern** | Namespace enum mapper (`XxxSurfaceCardViewModel.state(...)`) for card; `@Observable` class for detail | Mirrors P1 — stateless card mapper avoids cache invalidation; detail VM owns range + async load |
| **Per-surface SQL helper shape** | One protocol method per surface returning a comprehensive `XxxActivityBreakdown` struct | Mirrors `aiActivityBreakdown(period:)` from P1; avoids per-detail-load fan-out of 3-5 SQL queries |
| **Headline metric per surface** | Xcode = "N builds · M tests"; IDEs = "N files in M workspaces"; Browsers = "N pages on M domains"; Zoom = "Nh meeting time"; Calendar = "N focus blocks · Mh" | Single-glance answer per surface; sub-stats fill the rest |
| **Detail screen aggregates layout** | 3 LeafSection-wrapped LeafCards (mirrors P1 ClaudeCodeDetailScreen.sessionsSection / topToolsSection / topProjectsSection) | Predictable visual grammar; reads top-to-bottom: counts → breakdown → list |
| **Chart slot** | Per-surface 7-day daily LeafSparkline (Xcode: builds; IDEs: file events; Browsers: navigations; Zoom: minutes; Calendar: focus minutes) | Same component as P1; SQL helper returns `[Double]` of length 7 (oldest → newest) |
| **Calendar carve-out** | Card-only (no detail aggregates) until P11 GCP gate clears; detail screen renders LeafEmptyState | Acceptance §10 P4 already blocks on GCP, no data flowing in production |
| **Settings sub-anchor** | `.id(SettingsSubsection.xxx)` on the corresponding LocalAppRow / observer row; chained ScrollViewProxy.scrollTo in `applyPendingTarget` | Minimal disruption; matches existing `SettingsSection` `.id()` pattern |
| **Surface order in implementation** | Xcode → IDEs → Browsers → Zoom → Calendar | Atomic-commit-per-step ordering: simplest payload (Xcode build/test counts) to most complex (Calendar with carve-out) |
| **Snapshot caching vs on-demand** | Card view-model reads `InsightsSnapshot` if pre-computed, falls back to "enabled — open for details" if not | Same pattern as P1 ClaudeCodeSurfaceCardViewModel; avoids expensive SQL per Home redraw |
| **`InsightsSnapshot` extension** | Add 5 optional `xxxActivity: XxxActivityBreakdown?` fields, all default `nil`. Snapshot builder NOT extended in this phase — fields stay `nil`, cards show "Open for details" headline. | Snapshot builder extension would touch every existing snapshot consumer; defer to post-P2 follow-up |

---

## 3. Per-surface contract

### 3.1 Xcode

**Card headline:** `"N builds · M tests"` (counts via `xcode_build_started/_finished` + `xcode_test_run_started/_finished`).

**Card sub-stats** (`subStats` array, joined by ` · ` in view):
- `"K passed"` (build success count)
- `"L failed"` (build failure count)
- `"S schemes touched"` (distinct schemes via `xcode_scheme_changed`)

**Detail aggregates (3 sections):**
1. **Builds** — LeafCard with success vs failure counts (+ optional warning count if available in payload).
2. **Tests** — LeafCard with run count + pass/fail breakdown.
3. **Schemes & destinations** — LeafCard with top 5 scheme names (mono font) + top 5 destination buckets (`macos / ios_simulator / ios_device / etc.`).

**Chart:** 7-day daily build count sparkline.

**SQL helper:** `xcodeActivityBreakdown(period: DateInterval) throws -> XcodeActivityBreakdown` reads `events` table filtered by `signal_type='content'` (or whatever Track-6 P2 emitter uses — verify in Stage 5 first commit) AND `payload_json->>'event_kind' IN ('xcode_build_started', 'xcode_build_finished', ...)`.

### 3.2 IDEs

**Card headline:** `"N files in M workspaces"` (file events count from `vscode_active_doc_changed`/`vscode_workspace_opened`/`jetbrains_recent_project_observed`).

**Card sub-stats:**
- `"VSCode-family: K events"` (sum across VSCode / Cursor / Insiders / VSCodium)
- `"JetBrains: L events"` (across the 13 JetBrains bundles)
- `"P fallback titles"` (count of `ide_window_title_observed`, only if non-zero — surfaces opt-in users)

**Detail aggregates (3 sections):**
1. **Per-IDE breakdown** — LeafCard with VSCode-family events count, JetBrains events count, fallback events count.
2. **Top workspaces** — LeafCard with top 5 `workspace_name` values (mono font).
3. **Top files** — LeafCard with top 5 `file_basename` values (mono font, may be empty if user has only window-title fallback enabled).

**Chart:** 7-day daily event-count sparkline (any IDE event kind).

**SQL helper:** `idesActivityBreakdown(period:) throws -> IDEsActivityBreakdown` filters by 4 event_kinds + groups by `workspace_name` / `file_basename` / IDE family classification (helper static function maps bundle ID → IDE family).

### 3.3 Browsers

**Card headline:** `"N pages on M domains"` (page count via `safari_tab_navigated`/`chrome_tab_navigated`/`arc_tab_navigated`; distinct domains via URL parsing of `currentURL` field — already domain-filtered upstream).

**Card sub-stats:**
- `"Safari: K"` / `"Chrome: L"` / `"Arc: P"` (per-browser navigation count; only non-zero browsers surfaced)
- `"B bookmarks added"` (sum of positive `delta_count` from `safari_bookmark_changed`/`chrome_bookmark_changed`, if non-zero)

**Detail aggregates (3 sections):**
1. **Per-browser breakdown** — LeafCard with Safari / Chrome / Arc page counts + activations.
2. **Top domains** — LeafCard with top 5 domains (mono font) + count per domain.
3. **Bookmark deltas** — LeafCard with bookmark events count (signal of personal-library churn; surfaced because the user opted in).

**Chart:** 7-day daily navigation-count sparkline.

**SQL helper:** `browsersActivityBreakdown(period:) throws -> BrowsersActivityBreakdown`. Domain extraction via existing `URLComponents.host` parsing — store helper in `Insights/Helpers/URLDomainExtractor.swift` (small static func, no new tokens, no schema).

### 3.4 Zoom

**Card headline:** `"Nh meeting time"` (sum `duration_ms` across `zoom_meeting_ended` events, formatted as hours).

**Card sub-stats:**
- `"K meetings"` (count of `zoom_meeting_started`)
- `"L calendar-linked"` (count of `zoom_meeting_calendar_linked`)
- `"P ad-hoc"` (= K − L, only surfaced if positive)

**Detail aggregates (3 sections):**
1. **Meeting totals** — LeafCard with count + total duration.
2. **Calendar linkage** — LeafCard with linked vs ad-hoc counts (uses existing `event_links` join, see §5).
3. **Longest meeting today** — LeafCard with a single highlight (longest `duration_ms` in the period).

**Chart:** 7-day daily meeting-minutes sparkline.

**SQL helper:** `zoomActivityBreakdown(period:) throws -> ZoomActivityBreakdown` reads `events` for 3 zoom event_kinds + joins `event_links` for linkage counts.

### 3.5 Google Calendar (carve-out)

**Card headline:**
- If OAuth `.connected` AND events flowing: `"N focus blocks · Mh"` (count of `google_calendar_focus_block_started` + sum of focus duration).
- If OAuth `.connected` AND no events: `"Captured · Waiting for events"` (placeholder — GCP gate).
- If OAuth not `.connected`: compact disabled row (already handled by Step 2 tactical fix).

**Card sub-stats** (when populated):
- `"K OOO blocks"`
- `"L working location entries"`

**Detail aggregates (deferred to P11):** Renders `LeafEmptyState` with "Detail aggregates land in a follow-up phase. Calendar capture requires GCP project verification (in progress)." copy.

**Chart:** 7-day daily focus-minutes sparkline (renders empty when no events flowing).

**SQL helper:** `googleCalendarActivityBreakdown(period:) throws -> GoogleCalendarActivityBreakdown` reads `events` for `google_calendar_*` kinds. Headline derivation: zero events → `nil` headline (card falls into "Waiting for events" branch in view-model mapper).

---

## 4. Code surface (new files)

### 4.1 LeafCore — public types (5 payload + 5 breakdown + 5 protocol methods)

```
Packages/LeafCore/Sources/LeafCore/Home/
  XcodeCardPayload.swift                  — Sendable struct, mirrors ClaudeCodeCardPayload
  IDEsCardPayload.swift
  BrowsersCardPayload.swift
  ZoomCardPayload.swift
  GoogleCalendarCardPayload.swift

Packages/LeafCore/Sources/LeafCore/Insights/
  XcodeActivityBreakdown.swift            — public struct + `.empty` static
  IDEsActivityBreakdown.swift
  BrowsersActivityBreakdown.swift
  ZoomActivityBreakdown.swift
  GoogleCalendarActivityBreakdown.swift

Packages/LeafCore/Sources/LeafCore/Insights/Helpers/
  URLDomainExtractor.swift                — `static func domain(of urlString: String) -> String?`
  IDEFamilyClassifier.swift               — `enum IDEFamily { case vscodeFamily, jetbrains, fallback }; static func family(forBundleID:) -> IDEFamily`

Packages/LeafCore/Sources/LeafCore/Insights/DerivedInsights.swift
  — extend protocol with 5 new methods (each with default = `.empty` in extension)
  — extend StubInsights with 5 overrides returning `.empty`

Packages/LeafCore/Sources/LeafCore/Insights/InsightsSnapshot.swift
  — add 5 optional fields: `xcodeActivity: XcodeActivityBreakdown?` etc., all default `nil`
  — extend init with default `nil` values (back-compat for all existing call sites)
```

### 4.2 LeafCorePrivate — prod SQL implementations

```
Packages/LeafCore/Sources/LeafCorePrivate/Prod/Insights/
  ProdInsights+XcodeActivity.swift        — SQL body for xcodeActivityBreakdown
  ProdInsights+IDEsActivity.swift
  ProdInsights+BrowsersActivity.swift
  ProdInsights+ZoomActivity.swift
  ProdInsights+GoogleCalendarActivity.swift
```

These are extensions on `ProdInsights` — keeps each surface's SQL isolated for review + diff readability. All SQL bodies stay in `LeafCorePrivate` (gitignored), only the protocol method signature is public.

### 4.3 Leaf — view-models + detail screens

```
Leaf/Models/
  XcodeSurfaceCardViewModel.swift         — namespace enum mapper, mirrors ClaudeCodeSurfaceCardViewModel
  IDEsSurfaceCardViewModel.swift
  BrowsersSurfaceCardViewModel.swift
  ZoomSurfaceCardViewModel.swift
  GoogleCalendarSurfaceCardViewModel.swift

  XcodeDetailViewModel.swift              — @Observable class, mirrors ClaudeCodeDetailViewModel
  IDEsDetailViewModel.swift
  BrowsersDetailViewModel.swift
  ZoomDetailViewModel.swift
  GoogleCalendarDetailViewModel.swift

Leaf/Views/Window/SurfaceDetail/
  XcodeDetailScreen.swift                 — mirrors ClaudeCodeDetailScreen
  IDEsDetailScreen.swift
  BrowsersDetailScreen.swift
  ZoomDetailScreen.swift
  GoogleCalendarDetailScreen.swift
```

### 4.4 Leaf — UI wire-up (modified files)

```
Leaf/Views/Window/Home/SurfacesSection.swift
  — replace 5 "Captured · Coming soon" placeholder cards with per-surface card wrappers
  — same pattern as ClaudeCodeCardWrapper

Leaf/Views/Window/Home/HomeView.swift
  — replace placeholder detail() switch with real per-surface screen instantiation

Leaf/Views/Window/Settings/LocalAppsSettingsSection.swift
  — add .id(SettingsSubsection.xcode) on the Xcode LocalAppRow
  — add .id(SettingsSubsection.zoom) on the Zoom LocalAppRow

Leaf/Views/Window/Settings/SystemObserversSettingsSection.swift
  — add .id(SettingsSubsection.ides) on the IDEStorageSettingsSection mount
  — add .id(SettingsSubsection.browsers) on the BrowserBookmarkRow group

Leaf/Views/Window/Settings/WindowSettingsView.swift
  — extend applyPendingTarget to chain `sub` scroll after section scroll
  — single ScrollViewProxy.scrollTo with sub.id when sub != nil, using a small delay
```

### 4.5 LeafCore tests

```
Packages/LeafCore/Tests/LeafCoreTests/
  XcodeActivityBreakdownTests.swift       — Sendable / Equatable + .empty defaults
  IDEsActivityBreakdownTests.swift
  BrowsersActivityBreakdownTests.swift
  ZoomActivityBreakdownTests.swift
  GoogleCalendarActivityBreakdownTests.swift
  URLDomainExtractorTests.swift           — edge cases: missing scheme, IDN, ports, IPs, file://
  IDEFamilyClassifierTests.swift          — every Track-6 P6 bundle ID + unknown fallback
```

### 4.6 LeafCorePrivateTests — SQL correctness tests

```
Packages/LeafCore/Tests/LeafCorePrivateTests/
  ProdInsightsXcodeActivityTests.swift     — seed Xcode events, assert counts + spark daily
  ProdInsightsIDEsActivityTests.swift
  ProdInsightsBrowsersActivityTests.swift
  ProdInsightsZoomActivityTests.swift
  ProdInsightsGoogleCalendarActivityTests.swift
```

Each seeds the in-memory test DB with known Track-6-shaped events, then asserts the breakdown.

---

## 5. Cross-cutting concerns

**Event-link join (Zoom only):** §3.4 "calendar-linked count" reads `event_links` table — Track-6 P5 already populates `(from_event_id, link_kind='zoom_to_calendar_meeting', ...)` rows. SQL is a single `LEFT JOIN event_links ON event_links.from_event_id = events.id AND event_links.link_kind = 'zoom_to_calendar_meeting'` + `COUNT(event_links.from_event_id)`. No new schema.

**Domain extraction (Browsers only):** `URLDomainExtractor` is a 10-line static helper around `URLComponents(string:)?.host?.lowercased()`. Edge case handling (file:// → return nil; IP → return as-is; IDN → no special handling, Swift's URLComponents already lowercases ASCII fragments). Tests cover the matrix.

**IDE family classification:** static helper, no closures, no allocations per call. Maps `ide_bundle_id` payload → `IDEFamily` enum. Source of truth: same bundle ID list as Track-6 P6 `VSCodeFamilyDispatcher.classify` and JetBrains list (13 bundles). Helper exported public for use in both detail screen aggregation and future filters.

**Settings sub-anchor scroll mechanics:** `applyPendingTarget` becomes:
```swift
private func applyPendingTarget(proxy: ScrollViewProxy) {
    guard let target = coordinator.consumePendingSettingsTarget() else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        withAnimation(.easeOut(duration: 0.25)) {
            proxy.scrollTo(target.section, anchor: .top)
        }
        if let sub = target.sub {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(sub, anchor: .top)
                }
            }
        }
    }
}
```
Sub-anchor scroll waits for section scroll to settle (0.35s ≈ 0.1 + 0.25). Sub IDs are `SettingsSubsection` enum values — already defined in `AppRoute.swift` from P1.

**Sparkline data:** Per-surface SQL helper returns `[Double]` of length 7 (oldest day → newest day, midnight-aligned). All values float `0.0` when no events; LeafSparkline handles `< 2` non-degenerate points gracefully (renders nothing per P1 convention).

---

## 6. Acceptance smoke matrix

Per-surface A–G smoke runs on author's Mac before the phase merge-pending state. Mirrors P1 §13.1 P2-collapsed row (single line in matrix).

| Step | Smoke check (per surface) |
|------|---------------------------|
| A | Default Home — surface renders compact disabled row when its store says OFF; `[Enable]` CTA visible. |
| B | Toggle Settings ON (per-surface flow: Local Apps Xcode/Zoom toggle; System Observers IDE / Browser bookmark toggle; Connections Google Calendar Connect). |
| C | Home updates within ≤1 redraw (≤500ms wall clock) — compact row promoted to full card with "Open for details" headline (or real headline if events already exist). |
| D | Tap card → detail screen pushes via NavigationStack. |
| E | Today/Week/Month tabs re-query; aggregates update within ≤500ms. |
| F | Back gesture (swipe / `⌘[`) returns to Home with scroll position preserved. |
| G | `[Enable]` on disabled row deep-links to Settings → exact sub-section (verifies sub-anchor scrolling). |

**Per-surface real-data validation:**
- **Xcode**: Build a project in Xcode → card headline transitions from "Open for details" to "1 build · 0 tests" (or similar) within ≤1 capture tick.
- **IDEs**: Open a workspace in VSCode → IDE workspace count increments. Switch active file → file count increments.
- **Browsers**: Browse 3 tabs on an allow-listed domain → page count = 3, domain in top-domains list. Browse a non-allow-listed domain → no card update (granularity rule honored).
- **Zoom**: Join + leave a Zoom meeting → "1 meeting · ~Xh" headline within ≤1 tick. If the meeting was on Calendar, "1 calendar-linked" sub-stat appears.
- **Calendar**: Connect Google Calendar OAuth (GCP-gated: if OAuth flow blocked, card renders "Captured · Waiting for events" — verify copy + sub-stats absent).

**Track-level smoke (run as P2-collapsed integration after all 5 surfaces land):**
- **AC-1** All 5 toggles OFF → 5 compact rows below Claude Code's enabled card (or compact row if Claude Code also OFF). Order matches `SurfaceCatalog.all`.
- **AC-2** All 5 toggles ON → 6 enabled cards visible (Claude Code + 5 new). Stack fits 1100×720 default window without horizontal overflow.
- **AC-3** Mixed state → enabled cards top, disabled below within Surfaces section.
- **AC-4** Privacy walkback: `grep -nE "tool_input|tool_response|command|absolute_path|note_body|email_subject|file_contents|attendee_email|debugger_state|raw_url|preview" Leaf/Views/Window/SurfaceDetail/ Packages/LeafCore/Sources/LeafCore/Home/ Packages/LeafCore/Sources/LeafCore/Insights/ | grep -v "//"` → 0 hits.
- **AC-5** `just check-tokens` clean (no new hex / pt literals, all D1 token consumers).
- **AC-6** `xcodebuild` 5/5 schemes green (Leaf / LeafAgent / LeafMCP / LeafTests / LeafCorePrivateTests).
- **AC-7** SPM tests green: P1 baseline + ≥35 new unit tests (5 payloads × ~3 each + 5 SQL × ~3-4 each + 2 helpers × ~5 each).
- **AC-8** `RelayBodyLeakageTests` continues to pass without modification (or with sentinel-injection extension covering 5 new payload structs).

---

## 7. Open questions / known gaps

1. **OQ-T7P2-1** Xcode payload completeness: Stage 0 discovery flagged that Track-6 P2 emitter payloads are built in `ProdXcodeAdapter` (LeafCorePrivate, gitignored). Stage 5 first commit must read the actual payload field names from that adapter before writing the SQL helper. If field names diverge from the spec's assumed shape, update the breakdown struct first.
2. **OQ-T7P2-2** Browser activation count vs navigation count: §3.3 surfaces "N pages" — should that count `*_tab_navigated` events only, or both nav + `*_tab_activated`? Resolution: count `*_tab_navigated` for headline (semantic = "loaded a page"); surface `*_tab_activated` sum separately in sub-stats if non-zero.
3. **OQ-T7P2-3** Zoom carve-out for empty `event_links`: if a Zoom meeting ended but the calendar linker hasn't run yet (≤15s grace window per Track-6 P5), the linked count temporarily reads as 0. Acceptable for MVP; document in detail screen as "Calendar linkage updates after sync".
4. **OQ-T7P2-4** Calendar OAuth state vs event presence: §3.5 has 3 branches. Verify in Stage 5 that `GoogleCalendarOAuthService.state == .connected` actually means events should flow (vs. token expired needs re-auth). If state has a `.reconnectNeeded` case, card should render the same `[Connect]` row as `.notConnected`.
5. **OQ-T7P2-5** `InsightsSnapshot` extension scope creep: §2 decision defers snapshot builder extension to follow-up. If review surfaces that card view-models pulling on-demand from `DerivedInsights` per body pass is a perf concern, escalate to extend `InsightsSnapshot` in this phase (would add ~5 SQL queries to snapshot build, run once per Home refresh — still bounded).

---

## 8. Carry-overs

- **Snapshot builder extension** (OQ-T7P2-5) — if not done in this phase, P11 should evaluate measured perf cost.
- **Calendar aggregates** — Section 3 LeafEmptyState today; full aggregates land in P11 if GCP gate clears, otherwise stays empty.
- **Browser top-domains sort** — current spec is descending count; v1.1 could surface "longest time on" via per-domain dwell-time, requires session aggregation across navigation events (heavy SQL, deferred).
- **Per-IDE deep-link** — Settings sub-anchor lands on `IDEStorageSettingsSection` parent; v1.1 could land on the specific VSCode / JetBrains toggle row.
- **Sub-anchor sub-IDs across all surfaces** — only `.ides` / `.browsers` / `.xcode` / `.zoom` / `.claudeCode` exist in the enum today; future surfaces will need new cases.

---

## 9. References

- **P1 spec** — `docs/superpowers/specs/2026-05-17-track-7-ui-surface-polish-design.md` (§4 SurfaceCard contract, §5 SurfaceDetailLayout contract, §8 Empty state matrix, §13.1 P2-collapsed smoke row).
- **Track-6 P2** spec — Xcode payload field names and emitter behavior.
- **Track-6 P3** spec — Browsers per-tab state-machine + per-domain granularity rule.
- **Track-6 P4** spec — Google Calendar OAuth + syncToken polling + transition derivation.
- **Track-6 P5** spec — Zoom event-link mechanism + duration tracking.
- **Track-6 P6** spec — VSCode-family parser + IDE bundle list + window-title fallback.
- **CLAUDE.md** — workflow conventions for 8-stage one-phase-one-session, pre-push checklist for `gundemtech/leaf` public repo.
