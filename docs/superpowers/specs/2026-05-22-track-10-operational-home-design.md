# Track-10 — Operational Home master design

**Status:** APPROVED (brainstorm landed 2026-05-22). User-driven UX redesign of the Home dashboard surface following Track-9 wrap manual smoke findings.
**Source:** Track-9 SHIPPED tip `16c5713c` (= `origin/dev`) manual smoke findings — 6-block Home reads as quantified-self productivity tracker, not developer-context-helper. Track-9 substrate is correct; Track-10 reshapes the UI surface on top of it.
**Branch baseline:** Track-10 phase branches off `feature/track-10-operational-home` (off `dev` = Track-9 wrap). T1 opens the Track-10 collective substrate branch. Subsequent T2..T9 phase branches FF into Track-10 collective. T9 wraps → push to `origin/dev` (NOT `main` — main waits for explicit collective merge approval per user instruction).
**Decomposition target:** 9 phases (T1..T9), one phase = one Claude Code session per `.claude/shared/conventions.md` 8-stage workflow.

---

## 1. Goal

Reshape Home as an **operational console for a developer in a 10-20 person startup** — what's happening now / where did I stop / what needs me / who's around / what to say at standup — and drop the quantified-self framing where it leaked through Track-8 → Track-9.

Track-9 wrap manual smoke revealed concrete UX failures despite substrate being correct:

- **TODAY 58022 switches** — counter renders raw input events not app transitions; substrate query bug.
- **TODAY pills missing Terminal** — author's main capture app silent because Share Controls default OFF with no onboarding template wiring.
- **YOU·NOW branch + Linear ID empty** for non-Xcode work — Terminal / iTerm don't trigger per-IDE branch deriver dispatch.
- **WHERE STOPPED stuck empty** — C-25 sleep/wake gap (own post-Track-9 phase).
- **WITH YOU ON THIS empty** + scope too narrow ("same task only" — what user wants is broader team radar).
- **INBOX empty** until Layer B + D3 detection lights up — no actionable signal day one.
- **Analytics chart confusing** — single-Y-axis pragmatic chart with aiRatio×100 trick reads as "100 minutes" not "80%".
- **Empty states honest but inert** — no actionable hints, no deep-link to relevant Settings sub-section.

Track-10 ships:

1. **RESUME hero** — big card on top, replaces small WHERE STOPPED, surfaces "yesterday context + Resume CTAs" with git delta info (commits ahead/behind, uncommitted file count) read in-process.
2. **TODAY anchor + YOU·NOW state badge** — keeps 5 metrics row (focused / AI ratio / sessions / switches / commits), drops per-app pill strip, compacts YOU·NOW state machine into a small badge inline. Switches counter substrate bug fixed in T1.
3. **NEEDS YOU** — INBOX renamed + scope tightened. Drops informational kinds, keeps action-bearing kinds (review-request / mention / openQuestion / blocker / build-failed / CI-failed / live-meeting).
4. **TEAM·N** — broader team pulse (replaces narrow WITH YOU ON THIS). Empty by default while Phase 5.4 stub returns []. Conditional CTA when org has >1 member.
5. **SINCE YOU WERE LAST ACTIVE** — delta timeline using UserDefaults `lastSeenAtMs` cursor. [Mark all as seen] button advances cursor explicitly.
6. **YOU'RE ON** — task session anchor (LEAF-ID · branch · session start · open files). Distinct from YOU·NOW (state mode) and from RESUME (yesterday). Today's task lens.
7. **RECAP + EOD** — standup-helper collapsibles at the bottom. Time-of-day auto-reveal (06:00-11:00 RECAP expanded, 17:00-23:00 EOD expanded).
8. **Analytics tab hide-by-default** — moves behind new `SettingsSection.advanced` toggle. Default OFF for new + existing users.
9. **Onboarding share-controls auto-template** — first-launch step pre-whitelists common dev app bundle IDs from a LeafCorePrivate moat list.

Track-10 is **not** a substrate enrichment track — it's a UI redesign on top of Track-9 substrate. Substrate-purity invariant interpreted moderately: in-process subprocess reads (`git rev-list`, `git status` per workspace) + UserDefaults persistence + targeted moat bug fixes are within scope; new event_kinds / migrations / SQLCipher schema changes / MCP tools are NOT.

---

## 2. Scope locks (brainstorm decisions, 2026-05-22)

| # | Decision | Value |
|---|---|---|
| 1 | Decomposition | Master spec + sub-phases (Track-9 pattern) |
| 2 | Granularity | **9 phases T1..T9 surface-per-phase** |
| 3 | Kill list | Analytics hide-by-default · per-app pills drop in TodayBlock · WITH YOU ON THIS dies (replaced by broader TEAM·N) · WHERE STOPPED small bottom card promoted to RESUME hero · "<1m" duration rows hide |
| 3' | Quantified-self counters | **KEEP** in TODAY anchor (focused / AI ratio / sessions / switches / commits). Discovery noted dropping the 5 from UI was suggested in author prompt but explicitly **deselected** during brainstorm Q3 |
| 4 | Substrate policy | **MODERATE** — in-process subprocess reads + UserDefaults persistence + targeted moat bug fixes OK; new event_kinds / migrations / SQLCipher schema changes / MCP tools NOT |
| 5 | Composition | **5 zones dense grid** (RESUME hero · TODAY+state-badge inline · NEEDS YOU ‖ TEAM·N · SINCE ‖ YOU'RE ON · RECAP/EOD collapsibles) |
| 6 | SINCE anchor | **Explicit Mark-all-as-seen** — UserDefaults `lastSeenAtMs` updates only on user action |
| 7 | RECAP/EOD visibility | **Time-of-day auto-reveal** — 06:00-11:00 RECAP expanded · 11:00-17:00 both collapsed · 17:00-23:00 EOD expanded · 23:00-06:00 both collapsed |
| 8.1 | Onboarding preset location | **LeafCorePrivate moat** (gitignored) — protocol `OnboardingShareTemplateProvider` in public, list in `LeafCorePrivate/.../ProdOnboardingShareTemplate.swift` |
| 8.2 | Switches counter substrate bug | **Surgical moat query fix** — patch `queryContextSwitchCount` to count distinct app transitions, not raw input events |
| 8.3 | Analytics hide UX | **New `SettingsSection.advanced` sub-section** with `showAnalyticsSection: Bool` UserDefaults toggle (default false) |
| 9.1 | NEEDS YOU scope | **Rename + drop low-urgency kinds** — keep action-bearing (review-request / mention / openQuestion / blocker / build-failed / CI-failed / live-meeting); drop commentOnMyWork / Calendar-class / mail-unread / reminder-due from default view |
| 9.2 | TEAM·N empty | **Conditional CTA when org > 1 member**; hidden for solo users |

---

## 3. Pillars of work

### 3.1 RESUME hero (T2 — big card on top)

Promotes Track-9 T7 small WHERE STOPPED bottom card to a hero on top of Home. Same substrate (`WhereStoppedSnapshot` with `anchorFilePath` / `anchorLine` / `recentLastCommit` / `wipSignals`) plus new **git delta info** read in-process from the workspace `.git` directory:

- Commits ahead of merge base (`main` / default branch resolved at workspace-resolution time).
- Commits behind merge base.
- Uncommitted file count from `git status --porcelain`.

Substrate addition: new public LeafCore protocol `GitDeltaReader` (`read(forWorkspacePath:) -> GitDeltaSnapshot?` returning `{ commitsAhead, commitsBehind, uncommittedCount, mergeBase }`). Moat impl `ProdGitDeltaReader.swift` runs subprocess `Process` invocations under timeout + cancellation. Failure modes (no workspace, not a git repo, network error fetching merge base, subprocess timeout) yield nil — block falls back to current shape without delta line.

Mockup contract (rendered):
```
RESUME — Вчера остановился (16h ago)
LEAF-204 · feature/track-9-substrate
Last touched 18:47 — StreaksCard.swift:84
Last commit (20:14) — fix(track-9-T10): a11y IMPORTANTs from Stage 6 sweep
WIP: 3 uncommitted · 4 commits ahead of main
[→ Resume]  [→ Linear LEAF-204]  [→ Diff with main]
```

CTAs:
- **Resume** — opens last anchor app via `NSWorkspace.shared.open` resolved through `LocalAppsStore` (existing pattern from YOU·NOW.away.Resume).
- **Linear** — opens `https://linear.app/{workspace_slug}/issue/{LEAF-NN}` via system browser.
- **Diff with main** — opens `https://github.com/{owner}/{repo}/compare/main...{branch}` via system browser. Button **hidden** when no GitHub remote is resolvable (no `git remote get-url origin` match OR non-GitHub remote OR offline).

### 3.2 TODAY anchor row + YOU·NOW state badge inline (T3)

TodayBlock keeps the 5-metric row (focused / AI ratio / sessions / switches / commits). The per-app pill strip below it was already dropped in T1 (Foundation). T3's only TodayBlock change is adding the inline YOU·NOW state badge.

YOU·NOW state machine (4 cases: active / inMeeting / deepWorkFocus / away) is compacted into a **state badge primitive** (`YouNowStateBadge`) rendered inline at the right edge of the TODAY metrics row. The full YOU·NOW block file is replaced by the compact badge — YouNowBlock.swift is deleted, YouNowStateBadge.swift is new.

Switches counter substrate bug is fixed in T1 (not T3) — moat patches `queryContextSwitchCount` to count distinct `attention_app_changed.bundle_id` transitions per session window, not raw input events. Real query body lives in `LeafCorePrivate/.../ProdInsights+TodayMetrics.swift`. Expected delta: 58022 raw → ~10-30 actual transitions.

### 3.3 NEEDS YOU (T4) — INBOX rename + scope tighten

InboxBlock renamed to NeedsYouBlock. Default filter `.actionable` (new `InboxFilter` case) filters from 14 Track-9 T8 InboxKinds:

- **Kept** (action-bearing, default-visible): `reviewRequest` · `mention` · `openQuestion` · `blocker` · `buildFailed` · `ciFailed` · `liveMeeting`.
- **Dropped from default view** (still queryable via filter chip "All"): `commentOnMyWork` · `calInviteDeclined` · `calUpcoming15min` · `calConflict` · `mailUnreadBucket` · `reminderDueToday` · `slackDM`.

Filter chips collapse to: `[NEEDS YOU · N]` (default = `.actionable`) · `[All · N]` (full list) · `[Reviews · N]` · `[Questions · N]` · `[Mentions · N]` · `[Alerts · N]`. The `[All]` chip preserves access to dropped kinds.

Header copy: "NEEDS YOU · N" (action-bearing count). Empty state copy: "Nothing waiting on you right now." (replaces Track-9 T8 "All clear.").

### 3.4 TEAM·N broader pulse (T6)

Replaces narrow WITH YOU ON THIS block. New block reads `recentTeammateSnapshots(maxAge: 15min, now:)` (existing `TeammatePresenceReader` protocol — stub today returns []; Phase 5.4 own track lights up DB-backed reader against `presence_history`).

Renders all active teammates (last-seen ≤ 15 min) as compact rows: `[avatar] · displayName · currentApp · branch?` · state badge (`active` / `inMeeting` / `deepWorkFocus` / `away`). Sort: state priority desc → lastSeen desc.

**Empty state policy** (Q9.2 = C):
- Solo user (`OrgService.memberCount == 1`): block hidden entirely — Home shorter.
- Team user (`memberCount > 1`) AND reader returns []: `LeafEmptyState` with CTA "Team presence sync coming soon" (no "Phase 5.4" jargon in user-facing copy) — block visible, acknowledges the feature gap honestly.
- Reader returns rows: block lit up with real teammates.

Phase 5.4 dep is the only Track-10 block waiting on substrate that's NOT shipped today. All other Track-10 surfaces use existing Track-9-shipped substrate.

### 3.5 SINCE YOU WERE LAST ACTIVE timeline (T5)

New block surfacing team / Layer B / D3 activity delta since `lastSeenAtMs` UserDefaults cursor:

- **Cursor semantics** (Q6 = C): UserDefaults key `leaf.ui.lastSeenAtMs: Int64`. Default = process boot timestamp on first read. Updates **only** on explicit user action — `[Mark all as seen]` button at block footer.
- **Delta sources** (substrate ready):
  - `linearActivity(period: DateInterval(start: lastSeen, end: now))` — issues touched, status transitions.
  - `githubActivity(period: ...)` — PR opens / merges / reviews / comments.
  - `slackActivity(period: ...)` — mentions / DM / huddle starts.
  - `openQuestions(period:)` filtered by `openedAtMs > lastSeen` (D3).
  - `openBlockers()` filtered by `startedAtMs > lastSeen` (D3).
- **Rendering**: most-recent-first list capped at ~20 rows. Older deltas folded into "+N older changes" footer expand. Each row: `[severity-dot] · "actor verb target" · {age} · [source meta]`.
- **Empty state**: "Nothing new since you last looked." Mark-all button hidden (no cursor to advance).

Timeline filters: All / Linear / GitHub / Slack / Detections — filter chips at block header.

### 3.6 YOU'RE ON anchor (T7)

New block surfacing **today's task session** — task-level lens distinct from YOU·NOW (instant-level state) and RESUME (yesterday-level context).

Substrate: existing `currentTaskIdentity()` (LEAF-ID · branch · repo · workspacePath) + new T2 `GitDeltaReader` (commits ahead of main) + `todayMetrics(now: today).focusedMin` for session focused time + new helper to surface open files in current workspace (read from most recent `xcode_active_doc_changed` / `vscode_active_doc_changed` / `jetbrains_recent_project_observed` events with `workspace_root == currentWorkspace`, capped at 3-5 basenames).

Mockup contract:
```
YOU'RE ON
LEAF-204 · feature/track-9-substrate · +5 ahead of main
Started 09:18 · 1h 32m focused so far
Open files: StreaksCard.swift · AnalyticsView.swift · WeeklyMetrics.swift
```

**No** intensity bars / "9s focused" / quantified-self counters in this block. Task lens, not observability lens.

Empty state: when `currentTaskIdentity()` returns nil (no LEAF-ID resolvable from branch / window-title — e.g., Terminal-only work) → informational copy "No active task identified — Leaf reads `LEAF-XXX` from branch names of foreground IDE workspaces." No CTA (no Settings sub-section for branch parsing exists today — would be its own substrate phase if user demand emerges; carried out-of-scope).

### 3.7 RECAP + EOD standup helper (T8)

Two collapsibles at the bottom of Home, time-of-day auto-reveal:

| Hours | Default state |
|---|---|
| 06:00–11:00 | RECAP expanded · EOD collapsed |
| 11:00–17:00 | Both collapsed |
| 17:00–23:00 | RECAP collapsed · EOD expanded |
| 23:00–06:00 | Both collapsed |

Header click manually toggles regardless of hour. Persist per-session manual override in `@State` (no UserDefaults — resets next launch).

**RECAP content** (morning standup helper):
- "Yesterday: N commits · closed LEAF-X, Y · reviewed M PRs"
- "Today: continuing LEAF-204"
- "Waiting on you: PR #141 awaiting your review (2d) · LEAF-187 question from Anton (1d)"
- "Blockers: Sasha input on relay rotation API shape"

**EOD content** (evening recap + tomorrow prep):
- "Today: N commits · closed LEAF-X · reviewed M PRs · D blockers resolved"
- "Tomorrow: resume LEAF-204 (where you stopped)"
- "Carries: PR #141 still waiting · Anton's question still open"
- "Clean break: nothing critical hanging"

All content via existing protocol APIs:
- `todayMetrics(now: yesterday/today).commitsCount`
- `linearActivity(period:).byStatus[.completed].count` + extract issue keys from `linearTransitions`
- `githubActivity(period:).byEventKind[.prReviewAuthored].count`
- `inboxItems(filter: .reviews/.questions)` filtered by age
- `openBlockers()` mapped to `excerpt` field

`now: yesterday` derives via `Calendar.current.date(byAdding: .day, value: -1, to: now)` — `todayMetrics(now:)` is testable per the existing protocol signature.

### 3.8 Analytics hide-by-default (T1)

Drops Analytics tab from default Sidebar. Keeps file `AnalyticsView.swift` + the 6 block files intact (post-Track-10 reversible).

Mechanism:
- New `SettingsSection.advanced` enum case + sub-view.
- UserDefaults key `leaf.ui.showAnalyticsSection: Bool` (default `false`).
- Sidebar filters `WindowSection.allCases` — skips `.analytics` when toggle is false.
- New users + existing users (no UserDefaults value) start with Analytics hidden. Power-users discover the toggle via Settings → Advanced and flip it on if desired.

The `WindowState.section = .analytics` route still works programmatically — only the sidebar entry is filtered. URL scheme `leaf://analytics` (if any future deep-link lands) bypasses the toggle.

### 3.9 Onboarding share-controls auto-template (T1)

First-launch onboarding gains a step (or augments existing `aiTools` / `localApps` step) — pre-populates `LocalAppsStore` whitelist + `ShareControls` enabled set from a moat-resident preset list of common dev app bundle IDs.

Mechanism:
- Public LeafCore protocol `OnboardingShareTemplateProvider` with method `defaultTemplate() -> [BundleAppEntry]`.
- Public factory `OnboardingShareTemplateFactory.register(_:)` — set by LeafCorePrivate at bootstrap time.
- Default impl: empty list (graceful for OSS / public clones).
- Moat impl `ProdOnboardingShareTemplate.swift` in `Packages/LeafCorePrivate/.../Prod/Onboarding/` (gitignored) — concrete bundle IDs live here, never in public `gundemtech/leaf`.

User flow:
- Step renders: "We pre-selected common dev apps. Tap to deselect any you don't want shared."
- One-click "Accept all" advances; per-app toggle adjusts before accept.
- Skip path: no auto-whitelist applied (preserves existing default-OFF behavior).

### 3.10 Empty-state copy + deep-link CTAs

Per-block empty states are designed inside each surface's own phase (RESUME T2 · NEEDS YOU T4 · SINCE T5 · TEAM·N T6 · YOU'RE ON T7 · RECAP/EOD T8). The contract below is the **target shape** per block — full implementation lives in respective phase specs.

| Block | Owner phase | Empty state copy | CTA |
|---|---|---|---|
| NEEDS YOU (no items) | T4 | "Nothing waiting on you right now." | (no CTA — empty is good) |
| TEAM·N (org > 1, reader empty) | T6 | "Team presence sync coming soon." | (no CTA — Phase 5.4 dep) |
| SINCE (no deltas since cursor) | T5 | "Nothing new since you last looked." | (no CTA) |
| YOU'RE ON (no LEAF-ID) | T7 | "No active task identified — Leaf reads `LEAF-XXX` from branch names…" | (no CTA — informational) |
| RESUME (no recent stop-point) | T2 | "Capture needs an idle window to land a stop-point." | → Diagnostics doc (C-25 known-issue) |
| RECAP (no yesterday data) | T8 | "Nothing captured yesterday." | (no CTA) |
| EOD (no today data) | T8 | "Nothing captured today yet." | (no CTA) |

**Cross-cutting in T1 (only)** — Layer B disconnected provider empty states in the existing **Connections tab** (Linear / GitHub / Slack rows). These are the inert empty states from Track-8 P9 polish carries that have no per-block ownership elsewhere:
- Linear disconnected → CTA "Connect Linear" → routes via `RouteCoordinator.pushConnections` with row scrolled-to-view
- GitHub disconnected → analogous
- Slack disconnected → analogous

T1 wires these 3 CTAs only. New Track-10 Home blocks design their own empty states inside their respective phases.

---

## 4. Phase decomposition

9 phases, one phase = one session. Each phase opens a fresh Claude Code session per `.claude/shared/conventions.md` 8-stage workflow (Discovery → Brainstorm → Spec → Plan → TDD impl → Independent review → Verification → Ship). This master spec is the **contract** that per-phase specs elaborate.

### **T1 — Foundation**

Groundwork phase. Touches:

- **Analytics hide-by-default** — new `SettingsSection.advanced` enum case + sub-view + UserDefaults `leaf.ui.showAnalyticsSection: Bool` toggle (default false). Sidebar `CaseIterable` filter for `WindowSection.analytics`.
- **TodayBlock pill strip drop** — remove pill rendering from TodayBlock body. Keep substrate emission (LeafMCP consumers preserved). `pillVisibleCap` constant carried for future re-add if requested.
- **Switches counter substrate bug fix** — moat patches `queryContextSwitchCount` in `ProdInsights+TodayMetrics.swift` to count distinct `attention_app_changed.bundle_id` transitions. Moat unit tests confirm transition count semantic (real query body in moat).
- **"<1m" duration rows hide** — across all blocks that render `formatRelative` / `formatDuration`, skip rendering when delta < 60s OR render as "now" instead of "<1m".
- **Onboarding share-controls auto-template** — new public `OnboardingShareTemplateProvider` protocol + factory + integration into existing onboarding flow (likely augmenting `localApps` step). Moat impl `ProdOnboardingShareTemplate.swift` lists preset bundle IDs.
- **Layer B Connections empty-state CTAs (cross-cutting, T1 only)** — add `onCTA` closures to Linear / GitHub / Slack disconnected empty states in `ConnectionsView` consuming `RouteCoordinator.pushConnections*`. New Home Track-10 block empty states are designed in their respective phases (see §3.10).

T1 scope: ~6 atomic commits. Acceptance: 5/5 schemes build · SPM tests green · `just check-tokens` clean · privacy walkback grep clean (no new payload reads) · manual smoke (Analytics tab gone by default + switches counter ~10 instead of 58k + onboarding step shows preset).

### **T2 — RESUME hero**

Big card on top of Home, replaces small WHERE STOPPED. Touches:

- **Public `GitDeltaReader` protocol** in `Packages/LeafCore/Sources/LeafCore/Git/GitDeltaReader.swift` — method `read(forWorkspacePath:) async -> GitDeltaSnapshot?`.
- **Stub impl** in public LeafCore returns nil (graceful fallback).
- **Moat impl** `ProdGitDeltaReader.swift` in `Packages/LeafCorePrivate/.../Prod/Git/` — `Process`-based subprocess invocations for `git rev-list --count`, `git status --porcelain --branch`, `git merge-base`. Real subprocess body lives in moat; timeout + cancellation discipline + sentinel walks.
- **`InsightsSnapshot.gitDelta: GitDeltaSnapshot?` defaulted field** + `InsightsReader.refresh()` gains a new sequential call (mirrors Track-9 T7 `recentLastCommit` composition pattern; exact call ordinal finalized at T2 brainstorm).
- **`ResumeHeroBlock.swift` new** at `Leaf/Views/Window/Home/Blocks/`. Consumes `snapshot.whereStopped` + `snapshot.gitDelta` + `snapshot.currentTaskIdentity` to render 4-line layout + 3 CTA buttons.
- **`WhereStoppedBlock.swift` deleted** — small bottom card superseded by ResumeHeroBlock on top.
- **HomeView.swift** Zone 1 = ResumeHeroBlock; LOC budget bump from 261 to ~310.
- **Sentinel-injection regression test** — git subprocess output never leaks workspace absolute paths (or full file contents) into RESUME card render. Sentinel `LEAKED_SENTINEL_T2_GIT_DELTA` walks subprocess stdout buffers.

T2 scope: ~8 atomic commits. Acceptance: existing T7 WhereStoppedBlock contract preserved as fallback (when gitDelta nil) · 5/5 schemes · SPM tests · sentinel-injection test green · manual smoke (open Leaf in a workspace with uncommitted changes → RESUME hero renders "+N ahead · K uncommitted").

### **T3 — TODAY + YOU·NOW badge inline**

Compact TODAY anchor row keeps 5 metrics, drops per-app pill strip (already done T1), adds YOU·NOW state badge inline at right.

- **`YouNowStateBadge.swift` new primitive** at `Leaf/Views/Window/Home/Primitives/` (or `Leaf/Views/Tokens/`). 4-state mapping (active green / inMeeting blue / deepWorkFocus amber / away grey) into a compact tinted capsule with state-name + optional duration suffix.
- **`YouNowBlock.swift` deleted** (replaced by inline badge). Block file removed from `Leaf/Views/Window/Home/Blocks/`.
- **`TodayBlock.metricsRow`** extended with trailing `YouNowStateBadge(state: snapshot.youNowState)` aligned right.
- **HomeView.swift** removes YOU·NOW block from layout composition (was Zone 3a in Track-9; now inline in Zone 2).
- **YouNowState substrate UNCHANGED** — same enum, same deriver, same `youNowState(now:)` API. Pure UI refactor.

T3 scope: ~4 atomic commits. Acceptance: badge renders in 4 visual states · existing YOU·NOW state machine tests stay green · 5/5 schemes · LOC budget preserved.

**SHIPPED 2026-05-22 · commit `5f3badc7`** (review-fix tip; impl C3 `99486842`). Per-phase spec: `docs/superpowers/specs/2026-05-22-track-10-T3-younow-badge.md`. Net `≈ −194 LOC` across Home views. Zero substrate diff.

### **T4 — NEEDS YOU rename + scope tighten**

InboxBlock renamed + filter scope changes:

- **File rename**: `InboxBlock.swift` → `NeedsYouBlock.swift`. `InboxFilterRow.swift` → `NeedsYouFilterRow.swift`. `InboxItemRow.swift` → `NeedsYouRow.swift`.
- **Default filter** changes from `.all` to new case `InboxFilter.actionable` (kept for future reuse — current `.all` filter shows everything for completeness).
- **`.actionable` admits matrix**: `reviewRequest` · `mention` · `openQuestion` · `blocker` · `buildFailed` · `ciFailed` · `liveMeeting`. Dropped from default visible list: `commentOnMyWork` · `calInviteDeclined` · `calUpcoming15min` · `calConflict` · `mailUnreadBucket` · `reminderDueToday` · `slackDM`.
- **Filter chip strip** updates: `[NEEDS YOU · N]` (= `.actionable`) · `[All · N]` · `[Reviews · N]` · `[Questions · N]` · `[Mentions · N]` · `[Alerts · N]`. (Removes the implicit `commentOnMyWork`-bearing filter coverage.)
- **Header copy** in NeedsYouBlock: "NEEDS YOU · N" instead of "INBOX · N". Empty state copy: "Nothing waiting on you right now."
- **`InboxFilter.actionable.admits(_:)`** static method on enum returns the 7-kind whitelist.
- **Substrate UNCHANGED** — same 14 InboxKinds, same `inboxItems(filter:query:)` API, same Track-9 T8 feeders. Pure UI filter + rename.

T4 scope: ~5 atomic commits. Acceptance: rename build-clean (all callsites point to new names) · filter-actionable unit test · 5/5 schemes · manual smoke (NEEDS YOU shows review-request / blocker / openQuestion if seeded; commentOnMyWork visible via "All" chip).

**SHIPPED 2026-05-22 · review-fix tip `e76f5e70`** (impl C4 `172c1135`; housekeeping merge `8408574b` brought T2.5 + dev-launch-reliability into operational-home before T4 C1). Per-phase spec: `docs/superpowers/specs/2026-05-22-track-10-T4-needs-you.md`. Net `+158 / −30 LOC` across 7 files (3 view renames detected at 78%/81%/90% + LeafCore enum + 2 test files + HomeView callsite). Zero substrate diff (DB/MCP/Registry/InboxFiltering all 0-line). Sentinel-injection EXEMPT per §6.

### **T5 — SINCE YOU WERE LAST ACTIVE**

New block + UserDefaults cursor:

- **`SinceLastActiveBlock.swift` new** at `Leaf/Views/Window/Home/Blocks/`.
- **UserDefaults key** `leaf.ui.lastSeenAtMs: Int64` — read via `LastSeenCursor` store (mirror `LocalAppsStore` pattern, `@Observable` for SwiftUI reactivity). Default = process-boot timestamp on first read.
- **`InsightsReader.refresh()`** gains new sequential calls for since-window subset: `linearActivity(period: DateInterval(start: lastSeen, end: now))` · `githubActivity(period:)` · `slackActivity(period:)` · `openQuestions(period:)` + `openBlockers()` filtered by `openedAtMs > lastSeen`. Existing today-period calls stay (TODAY anchor uses them). T5 brainstorm decides whether to add separate-period calls or to filter today results client-side per source — depends on substrate efficiency.
- **`InsightsSnapshot.sinceLastActiveItems: [SinceLastActiveItem] = []` defaulted field**.
- **`SinceLastActiveItem` struct** with `severity` / `verb` / `targetTitle` / `sourceMeta` / `tsMs` fields composed in InsightsReader from raw delta sources.
- **`[Mark all as seen]` button** in SinceLastActiveBlock footer — updates UserDefaults `lastSeenAtMs = now` → triggers `InsightsReader.refresh()`.
- **Filter chip strip** at block header: All / Linear / GitHub / Slack / Detections.
- **No new substrate** — pure composition of existing protocol APIs.

T5 scope: ~6 atomic commits. Acceptance: cursor updates persist across app launches · timeline renders deltas with severity dots · [Mark all] empties the list · 5/5 schemes · manual smoke (Anton merges a PR → SINCE shows it on next refresh).

### **T6 — TEAM·N broader pulse**

New block replacing narrow WITH YOU ON THIS:

- **`TeamNBlock.swift` new** at `Leaf/Views/Window/Home/Blocks/`.
- **`WithYouOnThisBlock.swift` deleted**.
- **`InsightsSnapshot.activeTeammates: [TeammateSnapshot] = []` defaulted field** — populated by existing stub `recentTeammateSnapshots(maxAge: 15min, now:)`.
- **Conditional rendering** — Block reads `OrgService.memberCount` (existing).
  - `memberCount == 1` → block hidden entirely.
  - `memberCount > 1` AND snapshot empty → `LeafEmptyState` with copy "Team presence sync coming soon." (no Phase 5.4 jargon).
  - `memberCount > 1` AND snapshot populated → compact teammate rows (style inherited from Track-8 P5 WithYouOnThisBlock, replaced here): `[avatar] · displayName · currentApp · branch?` · state badge (reuses T3 `YouNowStateBadge` primitive).
- **`InsightsReader.refresh()`** gains new sequential call `recentTeammateSnapshots(maxAge: 15*60, now:)`. Stub returns [] until Phase 5.4 lights up.
- **No new substrate** — reuses existing `TeammatePresenceReader` protocol. Phase 5.4 brings Block to life automatically.

T6 scope: ~4 atomic commits. Acceptance: solo user (memberCount==1) — block hidden · team user empty — CTA shows · existing WithYouOnThisBlock tests cleaned · 5/5 schemes.

### **T7 — YOU'RE ON anchor**

New block surfacing today's task session:

- **`YoureOnBlock.swift` new** at `Leaf/Views/Window/Home/Blocks/`.
- **Substrate composition**:
  - `snapshot.currentTaskIdentity` — LEAF-ID · branch · repo · workspacePath (Track-8 P1 substrate ready).
  - `snapshot.gitDelta` (T2 dep) — commits ahead of merge base.
  - `snapshot.todayMetrics.focusedMin` — session focused time.
  - **New helper** `openFilesInCurrentWorkspace(limit: 5)` — reads most recent `xcode_active_doc_changed` / `vscode_active_doc_changed` / `jetbrains_recent_project_observed` events with `workspace_root == currentWorkspace`, returns basenames. Public LeafCore protocol method + moat impl.
  - Session start time: derive from earliest `xcode_active_doc_changed` / IDE attention event today with matching `workspace_root` (read in `ProdInsights+CurrentTaskIdentity.swift` moat).
- **`InsightsSnapshot.currentSession: CurrentTaskSession? = nil` defaulted field** — bundles `taskIdentity` + `sessionStartMs` + `focusedMinSoFar` + `openFiles[:5]` for single-pass rendering.
- **Empty state** when `currentTaskIdentity()` returns nil: "No active task identified."

T7 scope: ~5 atomic commits. Acceptance: shows LEAF-ID + branch + +N ahead + focused min + open files · Terminal-only work (no IDE attention) renders empty state · 5/5 schemes.

### **T8 — RECAP + EOD collapsibles**

Two new collapsible blocks at bottom of Home:

- **`RecapBlock.swift` + `EodBlock.swift` new** at `Leaf/Views/Window/Home/Blocks/`.
- **`HomeView.swift`** adds Zone 5 — both blocks stack vertically at bottom.
- **Time-of-day auto-reveal logic**:
  - `@State expanded: Bool` initialized via `Calendar.current.component(.hour, from: now)` lookup against boundary table (06/11/17/23).
  - Header chevron icon + tap toggles `expanded`. Manual toggle persists for `@State` lifetime (resets on view rebuild).
- **RECAP content composition** (in `InsightsReader.refresh()`):
  - Yesterday commits: `todayMetrics(now: yesterday).commitsCount`
  - Yesterday closed Linear: `linearActivity(period: yesterday).byStatus[.completed]` map to issue keys via `linearTransitions` filtered by completed status type.
  - Yesterday reviewed PRs: `githubActivity(period: yesterday).byEventKind[.prReviewAuthored]` count.
  - Today current focus: `currentTaskIdentity().linearID + branch` (Track-8 P1 substrate, already loaded in snapshot).
  - Stale review-asks: `inboxItems(filter: .reviews)` filtered by `ageMs > 24h` map to top 3.
  - Open blockers: `openBlockers()` map to top 3 `excerpt` field.
- **EOD content composition**:
  - Today commits / closed Linear / reviewed PRs — analogous to RECAP with `now: today`.
  - Tomorrow prep: `recentWhereStopped(limit: 1)` resolves "where to resume" (T2 RESUME substrate reuse).
  - Carries: same stale-review + open-blockers lists from RECAP.
- **`InsightsSnapshot.standupRecap: StandupSnapshot? = nil`** defaulted field bundling both RECAP and EOD content into single struct.

T8 scope: ~7 atomic commits. Acceptance: auto-reveal works at hour boundaries · manual toggle overrides · 5/5 schemes · manual smoke at 10:00 (RECAP open) + 18:00 (EOD open) + 14:00 (both closed).

### **T9 — Polish + Track-10 wrap**

Closing phase:

- **A11y sweep** via general-purpose subagent (Track-8 P9 / Track-9 T10 pattern). Expected NITs applied inline; carry list to post-Track-10.
- **HIG sweep** manual — touch targets / WCAG AA contrast / focus rings / keyboard nav / animation durations.
- **Perf sweep** — `just check-tokens` 3-tier · zero raw `Color.` / `.font(.system(` · DateFormatter cached in static let · zero ForEach.indices.
- **Privacy walkback master grep** — narrow scope (all Track-10 Block files), 0 hits forbidden fields.
- **HomeView.swift LOC budget enforcement** — gate 6 (§7.2) hard caps at 310 LOC. T9 actively manages: if LOC exceeds cap, refactor block composition into a `HomeContent` helper view (Track-9 P3 pattern) before SHIPPED commit.
- **Manual smoke per zone** (Дима driver): RESUME hero hits all 3 CTAs · TODAY+badge renders in all 4 YOU·NOW states · NEEDS YOU shows actionable + "All" reveals dropped · TEAM·N conditional behaves correctly · SINCE timeline + Mark-all-as-seen cycle · YOU'RE ON shows session + open files · RECAP/EOD auto-reveal at correct hours.
- **current-state.md update** — replace Track-9 wrap paragraph with Track-10 SHIPPED paragraph.
- **Master spec §9.3 status flip** for resolved Track-10 carries.
- **Track-10 SHIPPED commit** on `feature/track-10-operational-home`.
- **Push to `origin/dev`** (NOT `main`). Дима sanity check + push.

T9 scope: 8-12 atomic commits including sweeps. Acceptance: 9/9 gates from §7.2 all green · manual smoke documented in commit body · branch pushed cleanly.

---

## 5. Substrate additions inventory

### 5.1 New event_kinds — **NONE**

Substrate-purity invariant preserved at the strict definition. Registry frozen at 198.

### 5.2 SQLCipher migrations — **NONE**

Total tables post-Track-10: 30 (M001-M018 + M024 + M026 + M027). Unchanged from Track-9.

### 5.3 ShareEventTypeKey registry delta — **0**

No new entries.

### 5.4 New substrate APIs (DerivedInsights / LeafCore additions)

All zero-DB / zero-event_kind. Pure derivations + in-process subprocess reads + protocol additions.

| API / Type | Phase | Returns / Shape | Implementation |
|---|---|---|---|
| `GitDeltaReader.read(forWorkspacePath:)` protocol | T2 | `GitDeltaSnapshot?` (commitsAhead, commitsBehind, uncommittedCount, mergeBase) | Public protocol + stub returns nil · Moat `Process` subprocess impl (`git rev-list --count` / `git status --porcelain --branch` / `git merge-base`) |
| `GitDeltaSnapshot` value type | T2 | `{ commitsAhead: Int, commitsBehind: Int, uncommittedCount: Int, mergeBase: String? }` | Public LeafCore, Equatable + Hashable + Sendable |
| `openFilesInCurrentWorkspace(limit:)` | T7 | `[String]` file basenames | LeafCorePrivate moat — reads recent IDE attention events filtered by workspace_root match |
| `CurrentTaskSession` value type | T7 | `{ taskIdentity: TaskIdentity, sessionStartMs: Int64, focusedMinSoFar: Int, openFiles: [String] }` | Public LeafCore |
| `SinceLastActiveItem` value type | T5 | `{ severity: Severity, verb: String, targetTitle: String, sourceMeta: String, tsMs: Int64, source: SinceSource }` | Public LeafCore; composed in `InsightsReader` from raw delta sources |
| `StandupSnapshot` value type | T8 | `{ recap: StandupRecap, eod: StandupEod }` bundling yesterday/today/carries narrative fields | Public LeafCore |
| `OnboardingShareTemplateProvider.defaultTemplate()` protocol | T1 | `[BundleAppEntry]` | Public protocol + factory · LeafCorePrivate moat list |
| `BundleAppEntry` value type | T1 | `{ bundleID: String, displayName: String, defaultEnabled: Bool }` | Public LeafCore |
| `InboxFilter.actionable` enum case | T4 | static `admits(_:)` predicate over 7 InboxKinds | Pure enum extension in public LeafCore |
| `LastSeenCursor` `@Observable` store | T5 | UserDefaults wrapper exposing `lastSeenAtMs: Int64` + `markAllAsSeen(now:)` | Public Leaf (UI tier) |

### 5.5 New UserDefaults keys

| Key | Phase | Type | Default | Purpose |
|---|---|---|---|---|
| `leaf.ui.showAnalyticsSection` | T1 | Bool | false | Sidebar Analytics tab visibility |
| `leaf.ui.lastSeenAtMs` | T5 | Int64 | process-boot ts (set on first read if absent) | SINCE YOU WERE LAST ACTIVE cursor; advances only on `[Mark all as seen]` user action |

RECAP/EOD manual toggle override considered + rejected per Q7 — `@State` only, resets on view rebuild (no persistence).

### 5.6 New MCP tools — **NONE**

15-tool inventory unchanged. Future `get_standup_summary` MCP tool — carry post-Track-10 if AI clients request.

### 5.7 New SwiftUI views

Per-phase block files listed in §4.

### 5.8 Killed / renamed views

| Action | File | Phase |
|---|---|---|
| Deleted | `Leaf/Views/Window/Home/Blocks/WhereStoppedBlock.swift` (small bottom) | T2 (superseded by ResumeHeroBlock) |
| Deleted | `Leaf/Views/Window/Home/Blocks/YouNowBlock.swift` | T3 (replaced by YouNowStateBadge primitive) |
| Deleted | `Leaf/Views/Window/Home/Blocks/WithYouOnThisBlock.swift` | T6 (replaced by TeamNBlock) |
| Renamed | `InboxBlock.swift` → `NeedsYouBlock.swift` | T4 |
| Renamed | `InboxFilterRow.swift` → `NeedsYouFilterRow.swift` | T4 |
| Renamed | `InboxItemRow.swift` → `NeedsYouRow.swift` | T4 |

`AnalyticsView.swift` + 6 Analytics block files — KEPT (hidden via UserDefaults, reversible).

---

## 6. ADR-010 invariants

Every payload read in Track-10 stays under the existing allowlist. New surfaces with privacy-relevant inputs:

1. **T2 `GitDeltaReader` subprocess output** — `git rev-list --count` returns numeric · `git status --porcelain --branch` returns file list + branch header. Moat impl strips file content (only counts uncommitted files, not their names). Sentinel-injection test `LEAKED_SENTINEL_T2_GIT_DELTA` walks subprocess stdout buffers; assert numeric-only fields reach RESUME card render.
2. **T7 `openFilesInCurrentWorkspace`** — reads basename via existing T1 (Track-9) `xcode_active_doc_changed.doc_path` allowlist + `vscode_active_doc_changed.workspace_root` + `jetbrains_recent_project_observed.workspace_root`. Basenames already shipped per Track-9 T7 contract; no new allowlist needed. Sentinel walkback already covered by existing T7 sentinel-injection test in `RelayBodyLeakageTests`.
3. **T5 `lastSeenAtMs` cursor** — UserDefaults value is a timestamp Int64, no payload data. No privacy surface.
4. **T1 onboarding share-controls preset** — bundle ID list (e.g. `com.apple.Xcode`) is metadata, not payload. No allowlist concern. Moat residency is for competitive moat, not privacy.

Master sentinel-injection regression test pattern: `RelayBodyLeakageTests.testEventBodyDoesNotLeakIntoPresenceState_TrackTen_T<n>` per applicable phase. **Only T2** ships a new sentinel-injection test (`LEAKED_SENTINEL_T2_GIT_DELTA` walks subprocess stdout). T1 / T3 / T4 / T5 / T6 / T7 / T8 / T9 exempt:
- T1 — moat bug fix + UserDefaults + onboarding (no payload reads).
- T3 — pure UI refactor (existing YouNowState substrate).
- T4 — pure UI rename + filter (existing 14 InboxKinds + Track-9 T8 walkbacks already cover).
- T5 — UserDefaults cursor + period-filtered existing protocol APIs (no new payload allowlist).
- T6 — `recentTeammateSnapshots` output (TeammatePresenceReader walkback already in Track-8 P5 / Track-9 lineage).
- T7 — `openFilesInCurrentWorkspace` reads existing T1 (Track-9) allowlisted basenames; existing Track-9 T1 sentinel walks `vscode_active_doc_changed.workspace_root` cover.
- T8 — RECAP/EOD compose Linear / GitHub / Slack / D3 fields all covered by existing Track-3 D1..D3 + Track-1 D3 walkbacks.
- T9 — polish phase; runs sweeps + master grep but writes no new payload-touching code.

---

## 7. Testing strategy

### 7.1 Per-phase TDD discipline

Each phase ships tests for:

- **Substrate API contract** — public protocol round-trips (Equatable + Hashable + Sendable + Codable where applicable).
- **Defaulted-init blast-radius** — fixture-callsite preservation for new `InsightsSnapshot` fields (Track-9 defaulted-init pattern, 9th iteration).
- **Filter / enum extension predicates** — `InboxFilter.actionable.admits(_:)` × 14 InboxKinds matrix.
- **Time-of-day boundary tests** — RECAP/EOD auto-reveal logic per hour-bucket.
- **Sentinel-injection regression** — where applicable per §6.

### 7.2 Per-phase verification gates

Each phase wraps with explicit gate checks:

1. **5/5 xcodebuild schemes** Debug build SUCCESS (LeafCore / LeafCorePrivate / Leaf / LeafAgent / LeafMCP).
2. **SPM tests green** — XCTest + Swift-Testing combined, 0 failures, recorded skipped count.
3. **`just check-tokens` 3-tier clean** — BASE + MIGRATION + RETIRED.
4. **Privacy walkback grep** — narrow scope (phase file set), 0 hits forbidden fields. Forbidden list (Track-9 lineage): `absolute_path` (outside allowlist) · `full_comment_body` · `raw_email` · `notes_body` · `email_subject` · `note_body` · `file_contents` · `raw_prompt` · `tool_input` · `tool_response` · `response_body` · `prompt`.
5. **Sentinel-injection test green** (per §6 applicable phases).
6. **HomeView.swift LOC budget** — ≤ 310 LOC post-Track-10 (bump from current 261 to accommodate new ResumeHeroBlock + RecapBlock + EodBlock placement).
7. **`InsightsReader.refresh()` SQL call count** monotonic — Track-9 ended at 23 calls; Track-10 ends in ~30-33 range (T2 git delta · T5 since-cursor subset across 5 sources · T6 active-teammates · T7 current-session composition · T8 standup yesterday+today composition).
8. **No new SQLCipher migrations** — `git diff dev -- Packages/LeafCore/Sources/LeafCore/DB/` empty per phase.
9. **No new ShareEventTypeKey entries** — `git diff dev -- Packages/LeafCore/Sources/LeafCore/Share/ShareEventTypeRegistry.swift` empty.

### 7.3 Track-10 master smoke (T9 wrap)

Manual click-through on author's Mac per §3 mockup parity per zone:

- **Zone 1 RESUME hero**: opens with full content (file:line + commit + git delta + 3 CTAs) when workspace + recent stop-point seeded. Falls back gracefully (file:line only, no delta) when no workspace resolved. Tap each CTA — Resume opens app · Linear opens browser · Diff opens GitHub compare.
- **Zone 2 TODAY + state badge**: 5 metrics render with sane values (switches ~10 not 58k). State badge cycles through active/inMeeting/deepWorkFocus/away as conditions change.
- **Zone 3 NEEDS YOU ‖ TEAM·N**: NEEDS YOU shows actionable kinds by default; "All" chip reveals dropped. TEAM·N hidden for solo user / shows CTA for team user.
- **Zone 4 SINCE ‖ YOU'RE ON**: SINCE shows deltas with severity dots; Mark-all-as-seen clears the list. YOU'RE ON shows LEAF-ID + branch + +N ahead + open files for active Xcode/VSCode session; empty state for Terminal-only work.
- **Zone 5 RECAP/EOD**: RECAP auto-expanded at 09:00 → closes at 11:01 → EOD auto-expanded at 18:00. Header click toggles regardless of hour.
- **Settings → Advanced → Show Analytics tab**: toggle ON → Analytics tab appears in sidebar; toggle OFF → tab hidden.
- **Onboarding share-controls auto-template**: fresh-install (or simulated via Defaults reset) walks through new step; "Accept all" pre-populates `LocalAppsStore.enabled` whitelist.

### 7.4 Independent code review per phase

Stage 6 spawns `general-purpose` subagent as code-reviewer. Verdict drives phase forward (APPROVE / APPROVE-WITH-NITS / REJECT). REJECT → fix-bundle commit on same branch before merge to Track-10 collective.

A11y sub-review per phase touching view layer — general-purpose subagent as a11y reviewer (Track-9 T10 pattern). Expected: 0 BLOCKERS, IMPORTANTs applied inline, NITs carry to T9 wrap polish.

---

## 8. Out of scope (carries)

Per scope locks + brainstorm:

- **Phase 5.4 DB-backed `TeammatePresenceReader`** — own track, lights up TEAM·N automatically. Track-10 ships empty-state behavior.
- **C-25 sleep/wake `ProdWhereStoppedDeriver` substrate fix** — post-Track-9 own phase. Until shipped, RESUME hero / WHERE STOPPED stays empty in closed-laptop scenario.
- **YOU·NOW branch + Linear ID for non-Xcode workspaces** — Track-9 §9.3 substrate carry. T5/T7 surfaces gracefully when `currentTaskIdentity()` returns nil for Terminal/iTerm.
- **Localization** (`Localizable.strings` extraction) — separate localization track. Track-10 ships hardcoded English.
- **AI narrative** ("describe my standup in words" / "compose EOD summary") — v1.1 BYOK track. T8 RECAP/EOD ships data-driven; AI narrative additive future.
- **RECAP/EOD configurable hour boundaries** — v1.1 if requested. Track-10 hard-codes 06/11/17/23.
- **TEAM·N row tap → per-teammate detail screen** — Phase 5.4 / own follow-up (Track-9 §9.1 C-12).
- **Resume CTA branch-deletion staleness** — v1.1 (Track-9 §9.1 C-8 / Track-8 P9 carry).
- **Substrate enrichment for git delta as an event_kind / queryable substrate** — `git_branch_delta_observed` event kind discussed in Q4 option C → rejected. Track-10 ships in-process read only; substrate-backed history of delta state — post-Track-10 if user demand.
- **Multi-week Analytics variants** — Track-9 §9.3 C-41 carry. Track-10 doesn't touch Analytics content beyond hide-by-default.
- **`get_standup_summary` MCP tool** — future if AI clients request standup queries via MCP.
- **TODAY pill strip re-add** — Track-10 drops per Q3.k4. If user demand returns, re-add as v1.1.
- **Settings → branch parsing / branch identity sub-section** — referenced as out-of-scope CTA target in §3.6 YOU'RE ON empty state. No Settings sub-section exists today; would be its own substrate phase if user demand emerges. Track-10 YOU'RE ON empty state ships informational copy without CTA.

---

## 9. Carry-overs

### 9.1 Disposition of pre-Track-10 carry-overs (Track-9 §9.3 + §9.1)

| Carry | Description | Track-10 disposition |
|---|---|---|
| Track-9 §9.3 C-25 | Sleep/wake `ProdWhereStoppedDeriver` substrate bug | OUT — own substrate phase post-Track-10 |
| Track-9 §9.3 (Track-9 wrap section) | TODAY 58022 broken switches | **RESOLVED T1** (substrate query fix) |
| Track-9 §9.3 (Track-9 wrap section) | TODAY pills missing Terminal | **OBVIATED T1** (pill strip dropped) |
| Track-9 §9.3 (Track-9 wrap section) | YOU·NOW branch + Linear ID empty for Terminal | **GRACEFUL T7 empty state** (carry substrate phase) |
| Track-9 §9.3 (Track-9 wrap section) | WHERE STOPPED stuck empty | **OUT — C-25 own phase** |
| Track-9 §9.3 (Track-9 wrap section) | WITH YOU empty + scope too narrow | **RESOLVED T6** (broader TEAM·N replaces) |
| Track-9 §9.3 (Track-9 wrap section) | INBOX empty until Layer B lights up | **PARTIAL T4** (NEEDS YOU empty state copy honest; substrate dep on Layer B remains) |
| Track-9 §9.3 (Track-9 wrap section) | Analytics chart confusing | **OBVIATED T1** (Analytics hide-by-default) |
| Track-9 §9.3 (Track-9 wrap section) | Empty states honest but inert | **RESOLVED T1** (cross-cutting deep-link CTAs) |
| Track-9 §9.1 C-5 | LocalAppsStore reactivity | **OPPORTUNISTIC** in T1 onboarding refactor; else carry |
| Track-9 §9.1 C-8 | Resume CTA branch-deletion staleness | OUT — v1.1 |
| Track-9 §9.1 C-12 | TEAM·N row tap teammate detail | OUT — Phase 5.4 |
| Track-9 §9.1 C-29 | `queryCommentsOnMyWork` viewer_login | OUT — substrate enrichment phase |
| Track-9 §9.1 C-38 | Real TopToolsCard substrate | OUT — Track-10 hides Analytics, defers question |
| Track-9 §9.1 C-39 | Per-hour PeakHour heatmap substrate | OUT — same |
| Track-9 §9.1 C-44 | Real dual-axis Chart | OUT — Analytics hidden by default |
| Track-9 T10 a11y 8 NITs | Design-system primitive audit / section labels / etc | **PARTIAL T9** (sweep applies what's relevant to new Track-10 blocks; remaining NITs carry forward) |

### 9.2 Track-10 emits new carries

| Carry | Description | Phase discovered | Disposition |
|---|---|---|---|
| C-T10-EMIT-T7H1 | `knownPrefixes` hardcoded `["LEAF"]` in `ProdInsights+CurrentTaskIdentity.swift:39`; GUN-NN branches resolve with `linearID = nil` → RESUME hero + YOU'RE ON task line drop leading ID. Local hot-fix `["LEAF", "GUN"]` landed in moat (not committed — gitignored). | T7 post-ship smoke 2026-05-23 | **RESOLVED Phase B** (commit `7ec9b2c2` 2026-05-23) — hardcoded `["LEAF", "GUN"]` ships for current users. LinearIDPrefixCache v1.1 live-sync deferred to multi-workspace onboarding trigger (not blocking current users). |
| C-T10-EMIT-T7H2 | `perIDEEarliestEventTodayMatchingWorkspace` returned nil for Terminal-only Claude Code workflow (no Xcode/VSCode/JetBrains attention event today matching workspace) → `Started 00:00` fallback. Local hot-fix added aiCollaboration `cwd` second-pass dispatch + `cwdWorkspaceMatches` helper (accepts canonical / parent / tilde / ancestor shapes); landed in moat. | T7 post-ship smoke 2026-05-23 | **RESOLVED Phase B** (commit `7ec9b2c2` 2026-05-23) — `SessionSource` enum {ide, aiCollaboration, fallback} added as 15th defaulted-init iteration on `CurrentTaskSession`. Moat refactored into symmetric `ideCandidateToday` + `aiCandidateToday` evaluators + `taskSessionCandidatesToday` dispatcher per brainstorm-gate "AI wins if more recent" (compare by latestTs DESC; ties IDE-preferred). Composer appends " via Claude Code" suffix when sessionSource == .aiCollaboration. |
| C-T10-EMIT-T7H3 | `focusedMinDwellSince(bundleID:)` single-bundle signature mis-attributed dwell when aiCollaboration fallback (C-T10-EMIT-T7H2) yielded the agent's own bundleID instead of foreground terminal. Local hot-fix changed signature to `(bundleIDs: [String])` + SQL `WHERE bundle_id IN (?, ?, ...)`; fallback returns `terminalFamilyBundleIDs UNION {loggedBundleID}` (Terminal/iTerm2/Ghostty/Warp/Alacritty/Kitty/WezTerm/Hyper). Landed in moat. | T7 post-ship smoke 2026-05-23 | **RESOLVED Phase B** (commit `7ec9b2c2` 2026-05-23) — `terminalFamilyBundleIDs` hoisted from moat-private to public `IDEFamilyClassifier.terminalFamilyBundleIDs: Set<String>` for cross-extension reuse. Moat references the public set via property accessor (single source of truth). 2 sentinel-injection regression tests added (`test_currentTaskSession_AICwdSentinelDoesNotLeak` + `test_currentTaskSession_AIWinsByLatestTs_NoCwdPathBytesEscape`) — closes the "currently moat-tested via happy path only" note. |
| C-T10-EMIT-T9-A11Y | 5 a11y NITs deferred from T9 a11y sweep (subagent verdict 2026-05-23): TeamNBlock "Team, N active" 0/1 pluralization edge; YoureOnBlock truncated taskLine VO read; SinceLastActiveBlock "Mark all as seen" missing `accessibilityHint`; RecapBlock/EodBlock empty-state VO refresh on header toggle (`.combine` on outer VStack); ResumeHeroBlock literal quote-marks audible in subject/WIP `.accessibilityLabel`. | T9 a11y sweep 2026-05-23 | **RESOLVED Phase A** (commit `110619f7` 2026-05-23) — all 5 NITs landed. TeamNBlock `headerA11yLabel(count:)` static helper; SinceLastActive `.accessibilityHint`; Recap/Eod outer VStack `.combine`; ResumeHero quote-marks stripped. |
| C-T10-EMIT-T9-HIG | 5 HIG NITs deferred from T9 HIG sweep (subagent verdict 2026-05-23): TeamNBlock avatar raw `32×32` literal → design token; StandupHeaderRow chevron raw `frame(width: 12)` → token; YoureOnBlock empty-state copy split into `LeafEmptyState(title:description:)` pattern; RecapBlock/EodBlock plain `Text` empty-state → `LeafEmptyState` pattern; ResumeHeroBlock manual `prefix(60)` truncation → native `.lineLimit/.truncationMode`. | T9 HIG sweep 2026-05-23 | **RESOLVED Phase A** (commit `110619f7` 2026-05-23) — all 5 NITs landed. Avatar `LeafSpace.xxl` + chevron `LeafSpace.md` (no new LeafSize enum — semantic spacing-scale mapping). YoureOn split. Recap/Eod adopt new `LeafEmptyState(style: .compact)` variant. ResumeHero drops hand-truncation (closes C-T10-EMIT-LOC-RESUMEHERO too). |
| C-T10-EMIT-T9-A11Y-PRIMITIVES | Design-system primitive a11y audit forward carry from Track-9 T10 — `LeafPill` / `LeafInput` / `LeafIconChip` as Button labels need consistent traits (`.isButton`, optional `.isSelected`). Currently each callsite manually adds traits. Hoist into primitive view modifier. | Track-9 T10 carry, re-affirmed T9 | **RESOLVED Phase A** (commit `18547c23` 2026-05-23) — `leafChipAccessibility(label:isSelected:)` view modifier (Leaf/Theme/Composites/ChipAccessibility.swift) hoists Button-wrapped LeafPill a11y. 3 callsites adopt: NeedsYouFilterRow / SinceFilterRow / WeekChipStrip today chip. `.isButton` inherits from Button auto. |
| C-T10-EMIT-T7-A11Y | 5 a11y NITs from T7 Stage 6 a11y reviewer (verdict 2026-05-23) originally tagged "T10" — section-label `.isHeader` discipline; WeekChipStrip today selection `.isSelected`; Timer-driven refresh accessibility announcements; copy polish; design-system primitive a11y audit. T9 a11y sweep closed 4 inline (.isHeader on RESUME/NEEDS YOU/SINCE/TODAY); 1 + WeekChipStrip remained. | T7 a11y reviewer 2026-05-23 | **RESOLVED Phase A** (commit `18547c23` 2026-05-23) — WeekChipStrip today `.accessibilityAddTraits(.isSelected)` landed via chip-strip modifier. Timer-driven refresh announcements + copy polish remain open as v1.1 enrichment if VO demand surfaces. |
| C-T10-EMIT-FLAKE | Pre-existing test flake `testWarmState_HappyPath_TrackD1` reproduced during T6/T7 verification but NOT introduced by Track-10. Re-run-once-passes pattern. Likely Linear GraphQL fixture timing. NOT a Track-10 emit. | T6/T7 verification 2026-05-23 | OUT — separate test-infra triage. Re-runs always pass. |
| C-T10-EMIT-STANDUP-HOURS | RECAP/EOD hour boundaries hardcoded `[6, 11)` morning / `[17, 23)` evening per master spec §8. v1.1 should expose Settings → Standup → "RECAP visible window" + "EOD visible window" pickers (per-user customization for time-zone shifters and night-shift users). | T8 design 2026-05-23 | OUT — v1.1 personalization. |
| C-T10-EMIT-MCP-STANDUP | `get_standup_summary` MCP tool — exposes T8 `StandupSnapshot` to user AI clients (Claude Code / Cursor). Currently substrate is view-only. AI consumer demand TBD — speculative. | T8 design 2026-05-23 | OUT — future if AI demand. |
| C-T10-EMIT-LOC-RESUMEHERO | `ResumeHeroBlock.swift` LOC drift 222 (T2 landing) → 242 (post-T9). +20 LOC accumulated from T2.5 fix-bundle + a11y trait. No hard cap in master spec for per-block budgets (only HomeView ≤ 310 gated); informational. T9 SHIPPED at 242. | T9 LOC verification 2026-05-23 | OPEN — informational drift log. Phase A HIG sweep simplified `commitSubjectLine` body but added 5-line explanatory comment → net 242 → 246 (4 LOC). Refactor opportunity if future work pushes past ~280; stays open as informational tracker. |

**Common follow-up proposal** — single new phase "Claude Code workflow
first-class in YOU'RE ON" subsumes T7H1/T7H2/T7H3. Brainstorm gate: should
aiCollaboration fallback ever WIN over IDE match (e.g. user briefly opens
Xcode to grep but actually works in Claude Code)? Current default is
IDE-first, but worth questioning during spec phase.

**A11y + HIG follow-up proposal** — single new phase "Track-10 design-system
polish + a11y close-out" subsumes T9-A11Y / T9-HIG / T9-A11Y-PRIMITIVES /
T7-A11Y. Tight scope (no substrate touch), high cumulative UX impact across
the operational console. Pair with `LeafEmptyState` adoption sweep across
RecapBlock/EodBlock to harvest a11y `.combine` automatically.

T7 spec §6.1 contains identical entries for H1/H2/H3 with deeper context —
this section is the **Track-10 wrap visibility** mirror for T9 / collective
merge prep.

---

## 10. References

- Track-9 master spec: `docs/superpowers/specs/2026-05-19-track-9-substrate-enrichment-design.md` (§9.3 backlog source).
- Track-9 T10 wrap spec: `docs/superpowers/specs/2026-05-21-track-9-T10-wrap-polish.md`.
- Track-8 master spec: `docs/superpowers/specs/2026-05-18-track-8-home-ux-design.md` (original 6-block mockup + substrate inventory).
- Whitepaper Home model: `~/Desktop/Leaf/leaf-docs/docs/surfaces/native-app.md` (public-safe surface description — Track-10 wrap updates this to operational console v0.4).
- `.claude/shared/architecture.md` — substrate baseline (Track-9 SHIPPED tip).
- `.claude/shared/conventions.md` — per-phase 8-stage workflow.
- ADR-010 walkback discipline — `RelayBodyLeakageTests` sentinel-injection lineage.
- Brainstorm artifacts (this session): `.superpowers/brainstorm/84305-1779401691/` (gitignored — Q1..Q9 visual mockups).

---

## 11. Workflow per phase

Each of T1..T9 runs in a fresh Claude Code session per `.claude/shared/conventions.md` 8-stage workflow:

1. **Discovery** — Explore subagent on phase-specific substrate state.
2. **Brainstorm** — `superpowers:brainstorming` skill, one question at a time, design sections per Q.
3. **Spec write** — `docs/superpowers/specs/2026-05-XX-track-10-T<n>-<short>.md`, self-review, user approve.
4. **Plan** — `superpowers:writing-plans` skill, atomic per-commit decomposition + explicit AC per step.
5. **Implementation** — `superpowers:test-driven-development` per step, sequential discipline.
6. **Independent review** — `superpowers:code-reviewer` subagent (or general-purpose acting as code-reviewer) + a11y review subagent on view-layer phases.
7. **Verification** — `superpowers:verification-before-completion` (gates per §7.2).
8. **Ship** — FF merge to Track-10 collective `feature/track-10-operational-home` branch; per-phase commit `docs(shared): Track-10 T<n> landed — current-state update`.

Track-10 collective wrap (T9) push to `origin/dev` only. Merge to `main` is a separate ship-prep session with explicit Дима sanity check + push.

---

## 12. Acceptance — Track-10 wrap (T9)

Track-10 is COMPLETE when:

1. All 9 sub-phase SHIPPED docs land on `feature/track-10-operational-home`.
2. T9 §7.3 master smoke documented per zone — all 5 zones verified visually + functionally.
3. 9/9 verification gates per §7.2 green at T9.
4. Manual smoke discovered no BLOCKER UX issues (NIT carries OK).
5. `current-state.md` Track-10 SHIPPED paragraph lands.
6. Whitepaper sync via `/sync-docs track-10-wrap` slash-command (separate session — public-safe summary in `~/Desktop/Leaf/leaf-docs/`).
7. Push to `origin/dev` clean (NOT main).

Track-10 → main collective merge is a separate session post-acceptance, gated on Дима sanity check + push.
