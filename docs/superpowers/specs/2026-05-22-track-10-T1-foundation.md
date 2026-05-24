# Track-10 T1 — Foundation phase spec

**Status**: Stage 3 (per-phase spec) closed. Authored 2026-05-22 from approved Stage 4 plan `~/.claude/plans/track-10-t1-foundation-giggly-graham.md` after Stages 1-2 brainstorm + CTO review pass (13 findings dispositioned).

**Branch**: `feature/track-10-operational-home` (off Track-9 SHIPPED tip `16c5713c` + master spec landing `06f2c8c5`).

**Master spec contract**: `docs/superpowers/specs/2026-05-22-track-10-operational-home-design.md` — §4 T1 · §3.8 · §3.9 · §3.10 · §5.4 · §5.5 · §6 · §7.2 · §11.

---

## 1. Goal

Land the **groundwork phase** for Track-10 — independent surfaces that unblock the rest of the track but ship value on their own. Five atomic changes:

1. **Analytics hide-by-default** — drop Analytics from default sidebar via UserDefaults toggle (`leaf.ui.showAnalyticsSection: Bool = false`). New `Settings → Advanced` sub-section surfaces the toggle. Reversible — `AnalyticsView.swift` + 6 Analytics block files kept intact.
2. **TodayBlock pill strip drop** — remove per-app pill rendering from `TodayBlock.swift` body. Substrate emission preserved as YAGNI-reserve (no current MCP consumer; cleanup candidate post-Track-10).
3. **Switches counter substrate bug fix (moat)** — `TodayMetrics.switchCount` semantic shifts from broken `rate × period/60` (≈58k inflation, dimensionally wrong) to direct count of distinct `attention_app_changed.bundle_id` transitions per day window (≈10-30 expected). Moat-internal patch (LeafCorePrivate gitignored).
4. **Onboarding share-controls foundation** — public `OnboardingShareTemplateProvider` protocol + factory + `BundleAppEntry` value type in LeafCore (additive, no consumer in C4).
5. **Onboarding share-controls integration** — new `OnboardingStep.shareControls` between `.aiTools` and `.team`; `ShareControlsStepView` with per-app toggles + "Accept all" / "Skip" CTAs; moat preset bundle list in LeafCorePrivate; provider register adjacent to `DerivedInsightsFactory.register` at `LeafApp.swift:88` (same `#if LEAF_PROD` gate).

Net: 5 atomic implementation commits + 1 spec landing commit = 6 commits. Zero substrate touches (no event_kinds / migrations / MCP tools / ShareEventTypeKey delta — registry frozen at 198). Public surface additions: 3 new types · 1 new enum case · 1 new `OnboardingStep` case · 1 new `UserDefaults` key.

T1 is sentinel-injection EXEMPT per master spec §6 — no new payload reads; the only new "data" is a hardcoded bundle-ID metadata list.

---

## 2. Brainstorm decisions

| Q | Decision | Reason |
|---|---|---|
| Q1 Onboarding step placement | `.shareControls` between `.aiTools` and `.team` | `.aiTools` already writes `LocalAppsStore.claude_code=true`; share-controls extends the capture-config arc. Logical flow: permissions (ax/fda) → capture-config (observers/aiTools/shareControls) → team. |
| Q2 Layer B Connections CTAs | DROPPED — emit carry to master spec §9.2 | Discovery showed all 4 `disconnectedBlock()` callsites already trigger OAuth directly via `Task { await <provider>OAuth.connect() }`. Not inert. Master spec was written before audit. |
| Q3 Commit count | 5 atomic implementation commits | C1 Analytics hide / C2 TodayBlock pill drop / C3 switches counter moat / C4 protocol+factory+type / C5 onboarding step + UI + moat preset. |
| Q4 `.advanced` Settings position | Between `browserAllowList` and `updates` | Order: background → folders → localApps → systemObservers → aiTools → browserAllowList → **advanced** → updates → privacy. Advanced = power-user toggles; updates/privacy stay support-footer. |
| Q5 Switches fix public API | NO public API delta — moat-internal | `TodayMetrics.switchCount: Int` contract unchanged. Moat patches the SQL pipeline. Public verify = manual smoke (switches ~10 not ~58k). |
| Q6 `BundleAppEntry` shape | `{ bundleID: String, displayName: String, defaultEnabled: Bool }` (master spec §5.4) | No `category` field — onboarding panel renders flat list. v1.1 may add category if UX needs grouping. |
| Q7 LocalAppsStore reactivity (Track-9 §9.1 C-5) | Defer to own phase | `ObservableObject` → `@Observable` migration is substantive — touches all consumer-side env injection. C-5 stays in Track-9 §9.1 / Track-10 §9.1 carry list. |
| Q8 `<1m` literal | Removed together with pill strip | Audit: `<1m` lives only at `TodayBlock.swift:193` inside `formatDurationCompact` helper. Pill drop removes helper entirely. `HomeRelativeTimeFormatter` already buckets `<60s` as "now"; no cross-cutting helper needed. |

---

## 3. Master spec deviations (amendments deferred to T9 wrap)

| Deviation | Master spec wording | T1 reality | Action at T9 wrap |
|---|---|---|---|
| Layer B Connections CTAs scope | §3.10 + §4 T1 line 251 | All `disconnectedBlock()` CTAs already trigger `<provider>OAuth.connect()` directly. Not inert. | Drop scope; emit §9.2 carry: "Cross-cutting `RouteCoordinator.pushConnections(provider:)` deep-link substrate — deferred until first consumer phase needs scroll-to-row anchor." |
| Switches counter method name | §4 T1 line 248 — "`queryContextSwitchCount` in `ProdInsights+TodayMetrics.swift`" | Moat actually calls `contextSwitchRate(period:)` and multiplies by period duration (dimensionally wrong formula: `switchRate × period.duration / 60`). No `queryContextSwitchCount` symbol exists. | Rename to "patches the switches counter pipeline (currently `contextSwitchRate × period.duration / 60`)". |
| Onboarding integration step | §4 T1 line 250 — "augmenting existing `localApps` step" | No `.localApps` step exists in `OnboardingStep` enum (cases today: welcome, ax, fda, observers, aiTools, team, done). | Rename to "new `.shareControls` step between `.aiTools` and `.team`". |
| Commit count target | §4 T1 line 252 — "~6 atomic commits" | 5 implementation + 1 spec = 6 total commits (matches "~6"). | No spec amendment — "~6" is approximate language. |
| Moat package path | Plan §"Files modified — moat" used `Packages/LeafCorePrivate/...` | Actual moat path is `Packages/LeafCore/Sources/LeafCorePrivate/...` (LeafCorePrivate is a target inside the LeafCore package, gitignored per `.gitignore:41-46`). | This spec already uses correct path. No master spec amendment (master spec doesn't pin moat path explicitly). |

---

## 4. Out of scope (T1 hard exclusion)

Carry to subsequent Track-10 phases or post-Track-10:

- **T2-T9 work** — RESUME hero / TODAY+badge inline / NEEDS YOU rename / SINCE / TEAM·N / YOU'RE ON / RECAP+EOD / polish.
- **Real ShareControls UI surface** — `share_event_types` DB runtime persistence + per-event-type toggle UI — Phase 5.4 / own track.
- **`RouteCoordinator.pushConnections(provider:)` + ConnectionsView scroll anchors** — Q2 carry. First consumer phase will decide.
- **`LocalAppsStore` reactivity refactor** — Track-9 §9.1 C-5 / own phase.
- **`BundleAppEntry.category` field** — v1.1 if onboarding UX demands grouping (Q6).
- **`TopToolsCard` substrate / dual-axis Chart / per-hour heatmap** — Analytics hidden by default; Track-9 §9.1 C-38/C-39/C-44 / own phase if Analytics resurfaces.
- **Fix `onChange(of: permissions.fdaGranted)` auto-advance bypass** — pre-existing bug at `OnboardingView.swift:54-56` jumps directly from `.fda` to `.team`, skipping `.observers`, `.aiTools`, `.shareControls` if user rapid-grants. Not introduced by T1; left alone.
- **`surfacePills` substrate field cleanup** — zero MCP consumers; cleanup candidate post-Track-10 if no consumer materializes.

---

## 5. Files modified

### Public surface (`gundemtech/leaf` visible)

```
Leaf/Models/AppRoute.swift                                    +1 case  (.advanced)
Leaf/Views/Window/Settings/WindowSettingsView.swift           +1 section render
Leaf/Views/Window/Settings/AdvancedSettingsSection.swift      NEW (~80 LOC)
Leaf/Views/Window/Sidebar.swift                               +@AppStorage instance prop + filter
Leaf/Views/OnboardingView.swift                               +1 step case + advance wiring + UI panel
Leaf/Views/Onboarding/ShareControlsStepView.swift             NEW (~120 LOC)
Leaf/Views/Window/Home/Blocks/TodayBlock.swift                -~30 LOC (drop pillStrip + helper)
Leaf/LeafApp.swift                                            +1 register line (inside #if LEAF_PROD)
Packages/LeafCore/Sources/LeafCore/Onboarding/
  BundleAppEntry.swift                                        NEW (~25 LOC)
  OnboardingShareTemplateProvider.swift                       NEW (~40 LOC, protocol + factory)
Packages/LeafCore/Sources/LeafCore/Insights/TodayMetrics.swift  +doc-comment refresh on `surfacePills`
Packages/LeafCore/Tests/LeafCoreTests/Onboarding/
  BundleAppEntryTests.swift                                   NEW (~30 LOC)
  OnboardingShareTemplateFactoryTests.swift                   NEW (~50 LOC)
docs/superpowers/specs/2026-05-22-track-10-T1-foundation.md   THIS SPEC
```

### Moat (LeafCorePrivate, gitignored per `.gitignore:41-46`)

```
Packages/LeafCore/Sources/LeafCorePrivate/Prod/Insights/
  ProdInsights+TodayMetrics.swift                             PATCH (switches counter pipeline)
Packages/LeafCore/Sources/LeafCorePrivate/Prod/Onboarding/
  ProdOnboardingShareTemplate.swift                           NEW (preset bundle ID list)
Packages/LeafCore/Tests/LeafCorePrivateTests/Insights/
  ProdInsightsTodayMetricsSwitchesTests.swift                 NEW (transitions semantic + midnight boundary)
Packages/LeafCore/Tests/LeafCorePrivateTests/Onboarding/
  ProdOnboardingShareTemplateTests.swift                      NEW (non-empty + reverse-DNS + dedupe)
```

---

## 6. Verification gates (per master spec §7.2)

Each commit gates on:

1. **5/5 xcodebuild Debug schemes SUCCESS** — LeafCore / LeafCorePrivate / Leaf / LeafAgent / LeafMCP.
2. **SPM tests**:
   - Public CI baseline: 3035 → expected ~3042 (+~7 net new = 3 `BundleAppEntryTests` + 4 `OnboardingShareTemplateFactoryTests`).
   - Local full-stack including moat: 3035 → expected ~3052 (+~17 = public +7 + moat ~10: 3+ switches transitions tests + 4 preset tests + ~3 churn).
3. **`just check-tokens`** 3-tier clean (BASE+MIGRATION+RETIRED).
4. **Privacy walkback grep** narrow scope (T1 file set), 0 hits forbidden fields: `absolute_path` (outside allowlist) · `full_comment_body` · `raw_email` · `notes_body` · `email_subject` · `note_body` · `file_contents` · `raw_prompt` · `tool_input` · `tool_response` · `response_body` · `prompt`.
5. **Sentinel-injection EXEMPT** per master spec §6 (no new payload reads).
6. **HomeView.swift LOC** ≤ 261 (T1 doesn't touch HomeView; defensive — Track-10 cap is 310 at T9).
7. **`InsightsReader.refresh()` SQL call count** — Track-9 baseline 23, T1 expected 23 (no new sequential calls).
8. **No new SQLCipher migrations** — `git diff dev -- Packages/LeafCore/Sources/LeafCore/DB/` empty.
9. **No new ShareEventTypeKey entries** — `git diff dev -- Packages/LeafCore/Sources/LeafCore/Share/ShareEventTypeRegistry.swift` empty.

Manual smoke (Дима driver at end of phase):

- Settings sidebar shows **no Analytics tab** by default. Settings → Advanced → toggle ON → Analytics row appears. Toggle OFF → row hidden.
- `WindowState.section = .analytics` programmatic route still renders `AnalyticsView` (sidebar filter is selection-list-only).
- TodayBlock renders only metricsRow (5 cells) with sane `switchCount` (~10-30 not 58000+). No pill strip.
- Reset onboarding (`defaults delete tech.gundem.leaf onboardingStep`) → relaunch → new `.shareControls` step renders between `.aiTools` and `.team`. "Accept all" writes ~7-14 `LocalAppsStore.enabled.<bundleID>=true` UserDefaults keys. "Skip" advances with no writes.

---

## 7. Implementation order — 5 atomic commits

Each commit follows TDD per `superpowers:test-driven-development` (red → green → refactor) where applicable. C1/C2 ship UI-only changes with no test substrate per Leaf codebase precedent — verified via build success + manual smoke. C3/C4/C5 ship moat+public tests via TDD.

### Commit 1 — Analytics hide-by-default

`feat(track-10-T1): Analytics hide-by-default + SettingsSection.advanced`

- `SettingsSection.advanced` enum case (between `browserAllowList` and `updates`).
- `AdvancedSettingsSection.swift` new view (`@AppStorage("leaf.ui.showAnalyticsSection")`).
- `WindowSettingsView.swift` insert render between `browserAllowList` and `updates`.
- `Sidebar.swift` — `@AppStorage` MUST be a View **instance property** (NOT inside a computed prop — property wrapper inside closure body doesn't bind to View invalidation graph, CTO finding #1). Computed prop reads it: `private var leafGroupItems: [WindowSection] { showAnalyticsSection ? [.home, .analytics] : [.home] }`.

No new tests (`@AppStorage` UI gate has no testable substrate per codebase precedent).

### Commit 2 — TodayBlock pill strip drop

`feat(track-10-T1): TodayBlock pill strip drop (substrate emission preserved)`

- Delete `pillVisibleCap` constant (`TodayBlock.swift:24`).
- Delete `pillStrip` computed prop (`:138-155`).
- Delete `formatDurationCompact(seconds:)` helper (`:188-194`).
- Delete pill rendering in body (`:53-56` conditional wrapping `LeafDivider` + `pillStrip`).
- Refresh `TodayMetrics.swift:29` doc-comment on `surfacePills` — strip "<1m" mention; rewrite to clarify substrate emission preserved for future consumers.

No new tests. Substrate `surfacePills` field unchanged.

### Commit 3 — Switches counter substrate bug fix (moat)

`fix(track-10-T1): switches counter — count distinct attention transitions (moat)`

TDD:

1. **Pre-audit**: grep `Packages/LeafCore/Tests/LeafCorePrivateTests/` for `switchCount` literal — only `InboxItemTests.swift:58` (unrelated `InboxItem.switchCount`). No moat TodayMetrics assertions block the fix. Public LeafCore tests have no `switchCount` literal at all (grep clean except the same InboxItem entry).
2. **RED**: `ProdInsightsTodayMetricsSwitchesTests.swift` — seed `attention` events anchored to `Calendar.current.startOfDay(for: now)` with bundle alternation pattern. Assert `todayMetrics(now: anchorNow).switchCount == expected_transitions`. Include midnight-boundary edge case (event straddling day boundary only counts on the day where the later event falls).
3. **GREEN**: Patch `ProdInsights+TodayMetrics.swift:48-49` — replace `switchRate × period.duration / 60` with direct query. New private helper `queryAttentionTransitions(periodStartMs:periodEndMs:)` reads `attention_app_changed` events ordered by ts, walks pairs, counts `prev.bundle_id != curr.bundle_id` transitions.
4. **REFACTOR**: minimal. Public `TodayMetrics.switchCount: Int` contract preserved. Day-window semantic explicit via existing `todayInterval(now:)` helper.

MCP semantic-shift risk: CTO grep verified zero LeafMCP consumers of `switchCount`. Pre-fix value was misleading; shift is corrective.

### Commit 4 — Public LeafCore onboarding substrate

`feat(track-10-T1): OnboardingShareTemplateProvider protocol + factory + BundleAppEntry`

TDD:

1. **RED**: `BundleAppEntryTests.swift` — Equatable/Hashable/Sendable round-trip (Codable DROPPED per CTO finding #4 — YAGNI). `OnboardingShareTemplateFactoryTests.swift` — (a) default provider returns `[]`; (b) `register(stub)` then `current.defaultTemplate()` returns stub's entries; (c) re-register replaces previous (last-write-wins). Test isolation: setUp registers sentinel + tearDown restores `EmptyOnboardingShareTemplateProvider`.
2. **GREEN**:
   - `Packages/LeafCore/Sources/LeafCore/Onboarding/BundleAppEntry.swift` — struct `{ bundleID: String, displayName: String, defaultEnabled: Bool = true }`.
   - `Packages/LeafCore/Sources/LeafCore/Onboarding/OnboardingShareTemplateProvider.swift` — protocol + `EmptyOnboardingShareTemplateProvider` default + `OnboardingShareTemplateFactory` enum singleton (`nonisolated(unsafe)` static + `NSLock` — pattern parity with `LocalAppsStore.sharedDefaults`, CTO finding #10 risk-accepted).

No consumer yet — wired in C5.

### Commit 5 — Onboarding step + UI panel + moat preset

`feat(track-10-T1): onboarding .shareControls step + LocalAppsStore preset apply`

TDD on moat preset; view-layer additive integration verified by build success.

1. **RED (moat)**: `ProdOnboardingShareTemplateTests.swift` — non-empty list; non-empty `bundleID` + `displayName`; reverse-DNS `bundleID` regex `^[a-z0-9]+(\.[a-zA-Z0-9-]+)+$`; no dupe `bundleID`.
2. **GREEN**:
   - `OnboardingStep.shareControls` enum case (between `.aiTools` and `.team`).
   - `OnboardingView.swift` — `stepContent` switch adds `.shareControls → ShareControlsStepView(...)`. Wire `.aiTools` skip path (`:263`) and `installHooks()` success (`:295`) to advance to `.shareControls` (was `.team`).
   - `ShareControlsStepView.swift` — `@State entries = OnboardingShareTemplateFactory.current.defaultTemplate()` snapshot; per-bundle `@State enabled: [String: Bool]`. ScrollView wrapping `LazyVStack` capped to `maxHeight: 220` (320pt-wide popover budget — CTO finding #5). Empty list case (public clone scenario where moat factory isn't registered) renders compact "Share controls will be configured later in Settings → Local Apps." + Continue.
   - `ProdOnboardingShareTemplate.swift` (moat) — list confirmed at implementation time. Categories per `.claude/shared/architecture.md`: IDEs (Xcode/VSCode/Cursor) · comms (Slack/Linear) · browser (Chrome) · terminal (Terminal/Warp) · AI Desktop (Claude for Desktop if installed). Claude Code excluded (already handled by `.aiTools`). All `defaultEnabled: true`.
   - `LeafApp.swift` — add `OnboardingShareTemplateFactory.register(LeafCorePrivate.ProdOnboardingShareTemplate())` adjacent to `DerivedInsightsFactory.register { ... }` at line 88, **inside the existing `#if LEAF_PROD` gate** (factory pattern parity; default empty provider stays for non-prod / public clone builds).

CTO finding #12 risk-accepted: 14 sequential `setEnabled` calls → 14 main-queue async hops on "Accept all". One-time onboarding event, no rendering thrash.

---

## 8. CTO review findings (from Stage 4 plan — disposition table)

13 findings audited at Stage 4. Highest-severity outcomes:

- **#1 CRITICAL** — Sidebar `@AppStorage` placement: FIXED inline (View instance prop, not computed-prop closure).
- **#2 HIGH** — `surfacePills` substrate emission preserved despite zero MCP consumers: risk-accepted (minimum-blast-radius T1; cleanup carry to post-Track-10).
- **#3 HIGH** — Switches semantic 1000× shift (~58k → ~10-30): risk-accepted (CTO grep verified zero LeafMCP consumers of `switchCount`; pre-fix value misleading, shift corrective).
- **#4 MEDIUM** — `BundleAppEntry.Codable` YAGNI: FIXED (Codable dropped; Equatable/Hashable/Sendable kept).
- **#5 MEDIUM** — `ShareControlsStepView` 14 entries vs 320pt popover budget: FIXED inline (ScrollView + `maxHeight: 220`).
- **#6 MEDIUM** — Vague "find LeafCore bootstrap point": FIXED (pinned to `LeafApp.swift:88`).
- **#7 MEDIUM** — Test timestamp flakiness: FIXED inline (anchor to `Calendar.current.startOfDay` + offset).
- **#8-13 LOW** — Risk-accepted with rationale or fixed inline (existing alpha cohort UX accept; dot count auto-derive; `nonisolated(unsafe)` pattern parity; test count delta clarified; sequential `setEnabled` accept; programmatic `.analytics` route already unreachable in current code).

Full disposition table preserved in plan `~/.claude/plans/track-10-t1-foundation-giggly-graham.md` § "CTO review findings".

---

## 9. Master spec amendments at T9 wrap

Carries from T1 to apply at Track-10 wrap polish phase:

1. §3.10 + §4 T1 line 251 — drop "Layer B Connections empty-state CTAs" scope; emit §9.2 carry for cross-cutting `RouteCoordinator.pushConnections(provider:)` deep-link substrate.
2. §4 T1 line 248 — rename "patches `queryContextSwitchCount`" → "patches the switches counter pipeline (currently `contextSwitchRate × period.duration / 60`)".
3. §4 T1 line 250 — rename "augmenting existing `localApps` step" → "new `.shareControls` step between `.aiTools` and `.team`".
4. §9.2 NEW carry: "Cross-cutting `RouteCoordinator.pushConnections(provider:)` deep-link substrate (AppRoute case extension + ConnectionsView scroll-to-row anchors) — deferred until first consumer phase needs it (Q2 carry from T1)."
5. §9.2 NEW carry: "`TodayMetrics.surfacePills` substrate field cleanup — zero MCP consumers; drop substrate field + moat `queryPills` if no consumer surfaces post-Track-10."
6. §4 T1 line 249 — `"<1m" duration rows hide` master spec item was OBVIATED via C2 (pill strip drop). The `<1m` literal lived only inside `TodayBlock.swift`'s `formatDurationCompact(seconds:)` helper, which was deleted with the pill strip; `HomeRelativeTimeFormatter` already buckets `<60s` as `"now"` everywhere else. No separate hide-pass needed. Update master spec wording to "OBVIATED — formatDurationCompact deleted with pill strip via T1 C2" (cross-references Q8 brainstorm decision).

---

## 10. References

- Master spec: `docs/superpowers/specs/2026-05-22-track-10-operational-home-design.md`.
- Stage 4 plan (ephemeral, gitignored): `~/.claude/plans/track-10-t1-foundation-giggly-graham.md`.
- Track-9 wrap baseline: `docs/superpowers/specs/2026-05-21-track-9-T10-wrap-polish.md`.
- `.claude/shared/architecture.md` — Track-9 SHIPPED substrate (registry 198, 30 SQLCipher tables, 15 MCP tools).
- `.claude/shared/conventions.md` § "Одна phase = одна сессия" — 8-stage workflow.
- ADR-010 walkback discipline — `RelayBodyLeakageTests` sentinel-injection lineage.

---

## 11. Post-ship gaps + T2.5 closure (2026-05-22)

T1 C3 reduced the switches counter from ~58k → 853 (70× win, dimensionally
correct) but the new SQL had **no min-hold gate** — it counted every distinct
bundle transition including rapid Cmd-Tab flickers. Real-data smoke on Dima's
Mac (Fri 2026-05-22, ~5h workday) showed 853, still ~30-85× the UX target
"~10-30 expected" promised in §1.

Root cause: the post-T1 query body explicitly omitted a dwell gate
(`queryAttentionTransitionsCount` comment "skips the rate division and the
min-hold gate"). Promise unmet.

**T2.5 fix** (in `feature/track-10-T2-5-operational-followup`):

- Query extended with a destination-dwell gate via SQL window function;
  inclusive `>=` bound semantic. Implementation body in `LeafCorePrivate`.
- `contextSwitchMinHoldMs` constant (60_000 ms) lives in the same moat
  extension for easy retune.
- Test seeds updated: existing "60s spacing" test re-documented as
  "at-threshold, exercises inclusive `>=` bound"; four new fence tests
  cover flicker rejection / dwell just below threshold / dwell exactly at
  threshold / open-dwell at end of window.

**Acceptance criterion update**: switches < 50 on a typical 8h workday
(loosened from "~10-30" because the threshold approach still over-counts
return-to-base patterns — `A → B(<60s) → A` rejects the flicker A→B leg
but the return leg B→A still counts since A's own dwell qualifies).
Q1 risk-accept in the T2.5 spec; carry to a possible sustained-state-
machine follow-up if over-count becomes a UX issue.

T2.5 spec: `docs/superpowers/specs/2026-05-22-track-10-T2-5-operational-followup.md`.
