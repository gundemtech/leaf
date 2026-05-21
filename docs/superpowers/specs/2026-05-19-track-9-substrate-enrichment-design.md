# Track-9 — Substrate enrichment master design

**Status:** APPROVED (brainstorm landed 2026-05-19). Replaces stub `docs/superpowers/specs/2026-05-19-track-9-substrate-enrichment.md`.
**Source:** Track-8 master spec §9.1 unresolved carries (post-Phase 8.9 wrap) + a11y audit carry-forwards + Track-9 task statement in `.claude/shared/current-state.md` ("substrate enrichment for YOU·NOW depth — full §3 mockup parity").
**Branch baseline:** Track-9 phase branches off `feature/phase-8-1-substrate` (Track-8 wrap state — wraps P3..P9, FF'd into origin 2026-05-19). T1 opens new Track-9 collective substrate branch (e.g., `feature/phase-9-1-substrate` per Track-8 naming convention, or `feature/track-9-integration` per Track-7 — decided in T1 session). Subsequent T2..T9 phase branches FF into Track-9 collective. T10 wraps → ship-prep to main.
**Decomposition target:** 10 phases (T1..T10), one phase = one Claude Code session per `.claude/shared/conventions.md` workflow.

---

## 1. Goal

Bring the Home dashboard to 1:1 parity with master spec §3 happy-path mockup across **4 blocks** (TODAY / YOU·NOW / INBOX / WHERE STOPPED) and **lit up Analytics surface** (Phase 8.8 placeholder → real content). The visible mockup defines the contract.

Track-9 is the umbrella that swallows:
- Surgical substrate enrichment (collector payload extensions, new substrate APIs, sourceURL synthesis).
- **Layer B inbox feeders** — Phase 4.8 (Linear) + Phase 4.9 (GitHub) absorbed inside Track-9 (no separate phase outside).
- **Analytics Mid-tier MVP** (Phase 8.8 placeholder replacement — week chip strip, daily chart, streaks, peak hour, top tools, WoW deltas; AI rollup / Mode classifier / latency stats deferred).
- INBOX **full feeder expansion** across all shipped substrate (Linear / GitHub / Slack / Calendar / Zoom / Xcode build / Mail / Reminders / D3 detection).

Track-9 is **not** a UI redesign — block layouts already shipped Track-8 P3..P7. Track-9 lights up the substrate underneath so existing UI surfaces render mockup-parity content.

---

## 2. Scope locks (brainstorm decisions, 2026-05-19)

| # | Decision | Value |
|---|---|---|
| 1 | Outer scope | **+ Analytics umbrella** (surgical + Layer B feeders + Analytics) |
| 2 | Sequencing strategy | **Hybrid** — substrate-heavy phases ship silent (T1..T4), UI surface phases end-to-end per block (T5..T9), polish/wrap (T10) |
| 3 | INBOX feeder width | **Full expansion** — all shipped substrate sources route into INBOX (~10 feeders, +5-7 new `InboxKind` cases) |
| 4 | YOU·NOW branch deriver mechanism | **Hybrid Xcode-inline + IDEs-payload-extension** — `currentTaskIdentity()` reads last attention event's `doc_path` (Xcode) or `workspace_root` (VSCode/JetBrains, new payload field) → walks `.git/HEAD` |
| 5 | WHERE STOPPED anchor scope | **Full file:line** — AX `AXSelectedTextRange` integration in Xcode collector (new `xcode_active_doc_changed.line` payload field) + `WhereStoppedSnapshot.{anchorFilePath, anchorLine}` substrate fields |
| 6 | TODAY pill grouping | **Family-grouped, Xcode standalone** — substrate-side aggregation (~13 candidates: Claude / Xcode / IDEs / Browsers / Zoom / Calendar / Mail / Notes / Music / Reminders / Linear / GitHub / Slack). Top-8 visible per existing substrate cap |
| 7 | Analytics scope | **Mid-tier MVP** — week chip + daily chart + streaks + peak hour + top tools + WoW deltas. Mode classifier / AI rollup / latency stats → post-Track-9 phases |
| 8 | C-2 bonus error retention | **Bundled with T6** (TODAY UI phase) — `InsightsReader.State.error(message, lastKnown: InsightsSnapshot?)` refactor inline |

---

## 3. Pillars of work

### 3.1 YOU·NOW depth (T1 substrate + T5 UI)

Substrate gaps the brainstorm Discovery surfaced:
- `currentTaskIdentity()` today scrapes `branch` + `linearID` from window-title regex (`extractBranchToken` looking for `feature/...` token with `/`-and-known-prefix shape). **Xcode window title never matches** — Xcode renders `"HomeView.swift — Leaf"`, no branch token.
- `xcode_active_doc_changed` payload carries `doc_path` (Track-6 P2) but **no line number**.
- `vscode_active_doc_changed` (Track-6 P6) emits `workspace_name` + `file_basename` (sanitized by `IDETitlePathSanitizer`) but **no absolute workspace path** suitable for `.git/HEAD` walking.
- `jetbrains_recent_project_observed` (P6) emits project name from FSEvents on `recentProjects*.xml` but no live workspace path.
- `IntensityAggregator` (Track-4 S3, M018) substrate-ready but **default OFF** (Input Monitoring TCC dual-prompt) — UI needs UX hint for users on path to enable.

Track-9 closes:
- **Xcode**: inline substrate deriver walks `doc_path` up to `.git/HEAD`, parses ref → branch.
- **VSCode-family + JetBrains**: per-IDE collector payload extension adds `workspace_root` absolute path field (ADR-010 — absolute paths already in `xcode_active_doc_changed` precedent, sentinel-injection tests confirm no leak).
- **Xcode line**: AX `AXSelectedTextRange` integration in Track-6 P2 collector → `xcode_active_doc_changed.line` Int payload field. AX permission already granted — zero new TCC prompts.
- **Label tweak**: "Started HH:MM · Xm" → "X min focused" (matches mockup §3 wording).
- **Intensity UX hint**: when `intensityBars == 0` AND `IntensityAggregator` toggle OFF → small "Enable intensity monitoring" link → Settings deep-link.
- **.deepWorkFocus / .away rich enrichment**: workspace + LinearID display refinement for non-`.active` states.

### 3.2 TODAY hybrid pills + 5th cell + bonus C-2 (T6 UI)

Substrate gaps:
- `SurfacePill { id, label, count }` — UI ignores `count` field today (Phase 8.3 ships label-only rendering).
- `ProdInsights+TodayMetrics.queryPills()` aggregates by event_kind prefix match (e.g., `claude_%`) — produces **event count per surface**, not **attention-time** (capture-time semantics).
- No family-grouping logic — current substrate emits per-bundle pills. Mockup §3 implies Xcode standalone + IDEs family grouping.
- Layer B router branch (`pushHomeLayerBProvider`) wired Track-7 P4, but `ProdInsights+TodayMetrics` doesn't emit Linear/GitHub/Slack pills with action-noun counts today.
- `TodayMetrics.switchCount: Int` substrate-ready, but `TodayBlock.metricsRow` renders only 4 cells (focused / AI ratio / sessions / commits).
- `InsightsReader.State.error(message: String)` loses last-known snapshot — Phase 8.3 spec MS-5 contract not honored.

Track-9 closes:
- `SurfacePill { id, label, count: Int, kind: .captureTime | .actionNoun }` substrate shape (discriminator field).
- Family-grouped aggregation SQL: per-family bundle ID set → SUM(attention-time) for capture surfaces; per-provider event_kind set → COUNT(*) for Layer B.
- 13 candidate families: Claude / Xcode / IDEs (VSCode+JetBrains) / Browsers (Safari+Chrome+Arc) / Zoom / Calendar (Apple+Google) / Mail / Notes / Music / Reminders / Linear / GitHub / Slack. Substrate cap-8 preserved.
- `LeafPill` count rendering: `.captureTime` → "Claude 14m" / `.actionNoun` → "Linear 3".
- `TodayBlock.metricsRow` +1 cell (switches). ViewThatFits 5-cell wide + 2×3 / 3×2 narrow.
- C-2 bundled: `InsightsReader.State.error(message: String, lastKnown: InsightsSnapshot?)` refactor + `HomeContent` error banner above metrics + card renders last-known values gracefully.

### 3.3 WHERE STOPPED 4-line depth (T1 substrate + T7 UI)

Substrate gaps:
- `WhereStoppedSnapshot { excerpt, wipSignals, anchorEventId }` — no `anchorFilePath` / `anchorLine` / `recentCommitSubject`.
- M014 `where_stopped_log` schema — no `anchor_file_path` / `anchor_line` columns.
- `DerivedInsights.recentLastCommit(maxAgeMs:)` deriver — does not exist.
- `WhereStoppedBlock` renders 2-line excerpt + wipSignals join, doesn't match mockup §3 4-line layout.

Track-9 closes:
- `WhereStoppedSnapshot` field additions (Optional `anchorFilePath`, `anchorLine`, `recentLastCommit`).
- `ProdWhereStoppedDeriver` extension: fetch anchor event by ID → pluck `payload_json.doc_path` (T1 dep) + `.line` (T1 dep). VSCode/JetBrains anchors fall back to file-only (line nil).
- `recentLastCommit(maxAgeMs:)` deriver — query `gh_commit_pushed WHERE ts >= now - 4h ORDER BY ts DESC LIMIT 1` → `RecentCommitSnapshot { subject, branch, atMs }`.
- `InsightsReader.refresh()` adds 20th sequential SQL call (per Phase 8.7 reader pattern).
- `WhereStoppedBlock` 4-line layout: header "WHERE YOU STOPPED · <relative>" / `<anchorFilePath:line>` or `<excerpt>` fallback / `Last commit: "<subject>"` if ≤4h / WIP signals chips (P9 carry C-21 closes).

### 3.4 INBOX full feeder expansion + universal sourceURL synthesis (T2/T3 substrate + T8 UI)

Substrate gaps (canonical inventory from Stage 1 Discovery):
- `queryCommentsOnMyWork()` literally `return []` — Phase 4.9 dependency documented inline (viewer-login filter + payload `pr_url`/`issue_url` plumbing not shipped).
- `gh_pr_review_requested` event_kind — **not captured** anywhere in Layer B.
- `presence_state.github.viewer_login` — populated by 4.7.B partially, Track-9 finalizes for client-side filter consumption.
- Slack mentions captured Phase 4.7.B via `fetchMentionsReceived` (`slack_mention_received`) — substrate sits in DB but **not routed** into `ProdInsights+InboxItems`.
- `slack_thread_reply_aggregate` (Phase 4.7.A) — captured, not routed into INBOX.
- Linear `linear_comment_authored` (Phase 4.7.A) — captured, no client-side filter "comment to me" applied.
- Calendar declined invitations / 15min upcoming / conflicts — Track-6 P4 captures state changes (focus_block / ooo / working_location / meeting_observed) but no INBOX feeder.
- Xcode `xcode_build_finished` (Track-6 P2) with `errors > 0` — captured, not routed into INBOX as actionable item.
- Zoom `zoom_meeting_started` without matching `_ended` (Track-6 P5) — live meeting indicator, not routed.
- Mail unread bucket (Track-4 S2) + Reminders due-today (Track-4 S2) — captured, not routed.
- D3 `open_questions` + `blockers` (M014) — routed today (Phase 8.6), but `sourceURL` always nil (C-16 carry).
- `event_links` (M013) — exists but **not consumed** by inbox substrate. D3 detectors write `context_ref` columns directly to detection tables; event_links is decoupled.

Track-9 closes:
- `InboxKind` enum expansion — existing 5 (`reviewRequest` / `commentOnMyWork` / `mention` / `openQuestion` / `blocker`) + ~7 new (`cal_invite_declined` / `cal_upcoming_15min` / `cal_conflict` / `zoom_live_meeting` / `xcode_build_failed` / `mail_unread_bucket` / `reminder_due_today` + Slack DM bucket if T3 verifies substrate emits + `gh_pr_ci_red` + `gh_notification`).
- **Universal `InboxSourceURLDeriver`** — synthesizes URL from context refs at deriver boundary:
  - `linear_issue_ref` → `https://linear.app/{workspace_slug}/issue/{issue_key}` (workspace_slug from `presence_state.linear.workspace_slug` if present, fallback configurable per integration row)
  - `github_pr_ref` (`owner/repo/pull/N`) → `https://github.com/{owner}/{repo}/pull/{N}`
  - `github_issue_ref` (`owner/repo/issues/N`) → analogous
  - `slack_thread_ts` (`workspace/channel_id/thread_ts`) → `slack://channel?team={team_id}&id={channel_id}&message={ts}`
  - `cal_event_id` → `ical://{event_id}` (system handles)
  - `zoom_meeting_id` → `zoommtg://zoom.us/join?confno={id}`
  - `xcode_build_id` → opaque local ref, tap opens Xcode via `xcode://` URL scheme to project
- `ProdInsights+InboxItems` query expansion — 10 feeder methods (1 per source). Slack mentions / Linear comments / Calendar / Xcode build failures / Zoom / Mail / Reminders / D3 (existing + sourceURL synthesis). Phase 4.8 (Linear viewer-filter) lit by T2 substrate; Phase 4.9 (GitHub review_requested + notifications) lit by T3 substrate.
- `(kind, sourceURL)` aggregation activation — `aggregatedCount: Int` becomes real value (sums multiple comment events on same PR into 1 row with `(3)` suffix).
- `InboxItemRow` tap → `NSWorkspace.shared.open(sourceURL)` works for all new kinds.

### 3.5 Analytics surface (T4 substrate + T9 UI)

Substrate gaps:
- `DerivedInsights.weeklyMetrics(now:)` deriver — does not exist.
- `WeeklyMetrics` struct — does not exist.
- `AnalyticsView.swift` ships Phase 8.8 P8 as a 40-LOC honest placeholder ("Analytics view coming soon").

Substrate **already available** (no new substrate needed for):
- Phase 4.6.C `weekOverWeekDelta` synthesis
- Phase 4.6.C `longestUninterruptedWindow` derived metric
- Phase 4.6.C streaks (`commitStreak`, `issueCloseStreak`, `huddleParticipationStreak`)
- Phase 4.7.B `workload_pulse` (per-day assigned issues, cycle progress)
- Track-9 family-grouped TODAY aggregation logic (T6 substrate) — reusable for week-scoped top tools.

Track-9 closes:
- `WeeklyMetrics` struct: 8 × `TodayMetrics` daily summaries + `wowDelta: Double` + `peakHourLocal: Int?` (0..23) + `topToolsWeek: [SurfacePill]` (family-grouped, week-scoped) + 5 × `Streak { kind, count }`.
- `ProdInsights+WeeklyMetrics.swift` SQL math (reuses Phase 4.6.C synthesis + Track-9 family aggregation).
- `AnalyticsView` real surface: WeekChipStrip (8 chips) + DailyFocusedChart (SwiftUI Charts BarMark + LineMark AI ratio overlay) + StreaksCard (5 streaks with SF Symbol icons) + PeakHourCallout (24h heatmap mini-chart) + TopToolsCard (week-scoped TODAY pills) + WoWDeltaCallout (sparkline + delta).

---

## 4. Phase decomposition

10 phases, one phase = one session. Each phase has its own dedicated brainstorm + spec + plan in a fresh Claude Code session per `.claude/shared/conventions.md` workflow. This master spec is the **contract** that per-phase specs elaborate.

### Substrate-heavy half (silent ship)

#### **T1 — Collector payload extensions + AX line capture + recentLastCommit deriver**
- AX `AXSelectedTextRange` integration in Track-6 P2 Xcode collector → `xcode_active_doc_changed.line: Int` payload field.
- Track-6 P6 VSCode-family + JetBrains attention emitters → `workspace_root: String` payload field (absolute path, ADR-010 precedent established by `xcode_active_doc_changed.doc_path`).
- `DerivedInsights.recentLastCommit(maxAgeMs:)` substrate helper + `ProdInsights+LastCommit.swift` impl (returns `RecentCommitSnapshot { subject, branch, atMs }`).
- 3 × sentinel-injection regression tests (`xcode_p2_line`, `vscode_workspace_root`, `jetbrains_workspace_root`).
- Settings → System Observers: 2 new toggle rows (AX line capture, IDE workspace tracking — default ON).
- Substrate-only, no UI block touches.

#### **T2 — Phase 4.8 Linear inbox feeder**
- `linear_comment_authored_to_me` client-side filter (actor != viewer AND (mentioned == viewer OR parent.assignee == viewer OR parent.creator == viewer)) — derive from existing `linear_comment_authored` captured Phase 4.7.A.
- Payload `linear_issue_url` stable field composed at parser boundary (`https://linear.app/{workspace_slug}/issue/{key}`).
- Linear assignee→to_self / priority→Urgent / label→blocked / project health red — events captured Phase 4.7.C, add `ProdInsights+InboxItems` routing (no new event_kinds).
- ShareEventTypeKey: +1 entry (`linear_comment_authored_to_me`, default OFF).
- Substrate-only, INBOX rows fade in once present.

#### **T3 — Phase 4.9 GitHub inbox feeder + payload enrichment + Slack DM verify**
- NEW event_kinds: `gh_pr_review_requested` + `gh_pr_review_request_removed` (capture from GitHub `PullRequestEvent` action=`review_requested`/`review_request_removed`).
- Payload enrichment: `pr_url` + `issue_url` + `comment_url` stable fields across all `gh_pr_*` / `gh_issue_*` event_kinds.
- `presence_state.github.viewer_login` finalization (4.7.B partial → confirmed populated). Client-side filter `actor.login != viewer_login` for `commentOnMyWork` lit.
- `fetchNotifications` snapshot diff → synthetic `gh_notification_received` InboxItem feeder (derive from `presence_state.github.notifications` diff).
- Slack DM bucket — verify whether `slack_dm_received` event_kind / row currently emitted. If yes, route into T8. If no, carry post-Track-9.
- ShareEventTypeKey: +3 entries (`gh_pr_review_requested`, `gh_pr_review_request_removed`, `gh_notification_received` — all default OFF).
- Substrate-only.

#### **T4 — Analytics substrate (weeklyMetrics deriver)**
- `DerivedInsights.weeklyMetrics(now:)` returning `WeeklyMetrics` struct.
- `ProdInsights+WeeklyMetrics.swift` SQL math: 8 × `TodayMetrics` daily aggregation, WoW deltas vs days[-7..-13], peak hour from attention-time histogram, week-scoped top tools (reuses T6 family-grouped aggregation), 5 streaks (commit / issue-close / huddle / focus-session / heavy-pulse).
- Pure substrate phase. UI Phase 8.8 placeholder unchanged until T9.
- Integration test fixture: 14-day DB → exact metric values assertion.

### UI surface half (per-block end-to-end)

#### **T5 — YOU·NOW branch deriver + rich enrichment UI**
- `currentTaskIdentity()` per-IDE dispatch — Xcode reads `doc_path`, VSCode/JetBrains read `workspace_root` (T1 dep) → walks up to `.git/HEAD` → parses ref → `branch`.
- LinearIDExtractor applied to branch (uppercased) → `linearID`.
- `YouNowBlock` `.active` render: line 2 `<branch> · <linearID>` (line 1 contextLabel keeps "app · file").
- Label tweak: `"Started HH:MM · Xm"` → `"X min focused"` (matches mockup §3 wording).
- Intensity UX hint: when `intensityBars == 0` AND `IntensityAggregator` toggle OFF → small "Enable intensity monitoring" link → Settings deep-link.
- `.deepWorkFocus` enrichment: workspace + LinearID display if detectable.
- `.away` Resume CTA polish (LinearID display refinement, existing 4-gate behavior preserved).
- Sentinel-injection tests for branch deriver path.

#### **T6 — TODAY hybrid pills + 5th cell + bonus C-2**
- `SurfacePill { id, label, count: Int, kind: .captureTime | .actionNoun }` substrate shape (discriminator added).
- `ProdInsights+TodayMetrics` SQL refactor: family-grouped aggregation (13 candidates per scope lock #6).
- Per-surface attention-time SQL (capture surfaces): `SUM(duration_seconds) WHERE bundle_id IN (family_bundles)`.
- Per-provider action-noun SQL (Layer B): `COUNT(*) WHERE event_kind IN (...) AND ts >= today_start AND ts < today_end`.
- `LeafPill` count rendering: `.captureTime` → "Claude 14m", `.actionNoun` → "Linear 3".
- `TodayBlock.metricsRow` +1 cell (switches). ViewThatFits 5-cell wide + 2×3 / 3×2 narrow.
- C-2 bundled: `InsightsReader.State.error(message: String, lastKnown: InsightsSnapshot?)` refactor + `HomeContent` error banner above metrics + card renders last-known values gracefully (Phase 8.3 MS-5 contract closed).

#### **T7 — WHERE STOPPED 4-line layout**
- `WhereStoppedSnapshot.{anchorFilePath, anchorLine, recentLastCommit}` field additions (T1 substrate deps consumed).
- M014 schema migration M028 — adds `anchor_file_path TEXT NULL` + `anchor_line INTEGER NULL` columns to `where_stopped_log` (or stores in deriver-side join — design choice in T7 brainstorm).
- `ProdWhereStoppedDeriver` extension: fetch anchor event by ID → pluck `payload_json.doc_path` + `.line` (Xcode) or fall back to file-only / no anchor (VSCode/JetBrains).
- `InsightsReader.refresh()` adds 20th sequential SQL call `try insights.recentLastCommit(maxAgeMs: 4 * 60 * 60 * 1000)`.
- `WhereStoppedBlock` 4-line layout: header "WHERE YOU STOPPED · <relative>" / `<anchorFilePath:line>` or `<excerpt>` fallback / `Last commit: "<subject>"` if ≤4h / WIP signals chips.
- WIP chip styling (P9 carry C-21 closes — chip primitives reused from `LeafPill` family).

#### **T8 — INBOX full feeder expansion + universal sourceURL synthesis**
- `InboxKind` enum expansion: existing 5 + ~7 new cases per scope lock #3.
- `InboxSourceURLDeriver` utility (universal context_ref → URL synthesis, see §3.4).
- `ProdInsights+InboxItems` major query expansion: 10 feeder methods.
- `(kind, sourceURL)` aggregation activation: `aggregatedCount` real value.
- `InboxItemRow` UI refinement: severity dot tone for new kinds + aggregate `(N)` suffix + sourceURL deep-link works for all kinds.
- 10 × new InboxKind sentinel-injection tests (sourceURL synthesis doesn't leak body/title text into URL fragments).

#### **T9 — Analytics UI surface (Mid-tier MVP)**
- Replace `AnalyticsView.swift` placeholder with real surface.
- Components: `WeekChipStrip` (8 day chips) + `DailyFocusedChart` (SwiftUI Charts) + `StreaksCard` (5 streaks) + `PeakHourCallout` (24h mini-heatmap) + `TopToolsCard` (week-scoped pills) + `WoWDeltaCallout` (sparkline).
- `InsightsReader` extension fetches `weeklyMetrics(now:)` in `refresh()` → `InsightsSnapshot.weeklyMetrics: WeeklyMetrics?` defaulted Optional field.
- `AnalyticsContent(snapshot:)` consumer.
- Substrate-only fidelity (`just check-tokens` 3-tier clean, no raw `Color.` / `.font(.system(`).

#### **T10 — Polish + verification + Track-9 wrap**
- A11y sweep via general-purpose subagent (Track-8 P9 pattern).
- HIG sweep manual.
- Perf sweep (DateFormatter cache discipline, ForEach.indices, raw Color hits).
- C-24 cleanup: drop orphaned `InsightsSnapshot.recentActivity` substrate-side fetch from `InsightsReader.refresh()` (LeafMCP `RecentActivityTool` keeps own reader path).
- C-22 `formatRelative` further unification if new callsites emerged in T5..T9.
- Manual smoke per master spec §3 mockup parity per block.
- Track-9 substrate-branch wrap → ship-prep to main merge (collective branch state).

---

## 5. Substrate additions inventory

### 5.1 New event_kinds (Track-9 net)

| Event kind | Phase | Default | Notes |
|---|---|---|---|
| `linear_comment_authored_to_me` | T2 | OFF | Client-side filter discriminator on existing `linear_comment_authored` |
| `gh_pr_review_requested` | T3 | OFF | New GitHub PullRequestEvent action capture |
| `gh_pr_review_request_removed` | T3 | OFF | Symmetric removal capture |
| `gh_notification_received` | T3 | OFF | Synthesized from `fetchNotifications` snapshot diff (4.7.B) |
| `slack_dm_received` | T3 | OFF | **Conditional** — only if substrate verify confirms emission today; else carry |

Plus payload-only field additions (no new event_kinds):
- `xcode_active_doc_changed.line: Int` (T1)
- `vscode_active_doc_changed.workspace_root: String` (T1)
- `jetbrains_recent_project_observed.workspace_root: String` (T1)
- `linear_issue_url: String` stable field (T2, across multiple linear_* event_kinds)
- `pr_url: String` / `issue_url: String` / `comment_url: String` stable fields (T3, across multiple gh_* event_kinds)

### 5.2 SQLCipher migrations

| Migration | Phase | Purpose |
|---|---|---|
| M028 | T7 | `where_stopped_log` add `anchor_file_path TEXT NULL` + `anchor_line INTEGER NULL` columns (or deriver-side join — finalized in T7 brainstorm) |

**M025 freed** (Track-6 P2 reuse — `provider_snapshots` M015 already serves). No other new tables in Track-9 — all new substrate APIs read existing tables. **Total SQLCipher tables post-Track-9: 32** (M001-M018 + M024 + M026 + M027 + M028).

### 5.3 ShareEventTypeKey registry delta

| Phase | Net delta | Cumulative |
|---|---|---|
| Baseline (post-Track-6) | — | 195 |
| T2 (Linear feeder) | +1 | 196 |
| T3 (GitHub feeder) | +3 to +4 (incl Slack DM conditional) | 199 to 200 |
| Other phases | 0 | 199 to 200 |

All new entries default OFF per ADR-020. No payload-only field additions trigger registry rows (registry tracks event_kind emission discipline, not payload fields).

### 5.4 New substrate APIs (DerivedInsights additions)

| API | Phase | Returns |
|---|---|---|
| `recentLastCommit(maxAgeMs:)` | T1 | `RecentCommitSnapshot?` |
| `weeklyMetrics(now:)` | T4 | `WeeklyMetrics` |

### 5.5 New MCP tools

**None.** Track-9 does not expose Analytics surface through MCP. Future `get_weekly_metrics` tool — carry post-Track-9.

### 5.6 New SurfacePill / InboxKind / WhereStoppedSnapshot fields

- `SurfacePill { id, label, count: Int, kind: SurfacePillKind }` — adds `kind: .captureTime | .actionNoun` (T6).
- `InboxKind` enum cases: ~7 new (T8).
- `WhereStoppedSnapshot` adds `anchorFilePath: String?` + `anchorLine: Int?` + `recentLastCommit: RecentCommitSnapshot?` (T7).
- `YouNowActive` already has `branch: String?` and `linearID: String?` fields (Phase 8.1 substrate); T5 populates them via `currentTaskIdentity()` enrichment (no struct change).
- **InboxKind** is a client-side enum, **not gated by ShareEventTypeKey directly**. Inbox feeders read source event_kinds; each source event_kind (e.g., `xcode_build_finished`, `cal_event_observed`, `linear_comment_authored_to_me`) has its own ShareEventTypeKey registration (default OFF). Disabling source event_kind → corresponding InboxItem fades. No InboxKind-level toggle.

---

## 6. ADR-010 invariants

Every new payload field passes through privacy walkback discipline:

1. **`xcode_active_doc_changed.line` (T1)** — integer row number, no content. Sentinel-injection test inserts `LEAKED_SENTINEL_XCODE_LINE_P1` into AX text near selection range; assert never reaches `events.payload_json` or `presence_state.state_json`.
2. **`vscode_active_doc_changed.workspace_root` (T1)** — absolute path. Precedent: `xcode_active_doc_changed.doc_path` is already an absolute path captured Track-6 P2; UI surface strips to basename via `ActivityFeedMapper`. Sentinel walks file content adjacent to workspace and asserts non-leakage.
3. **`jetbrains_recent_project_observed.workspace_root` (T1)** — same shape as VSCode.
4. **`linear_issue_url` (T2)** — composed URL from `workspace_slug` + `issue_key`; no body / title / mention text. Sentinel injects `LEAKED_SENTINEL_LINEAR_T2` into adjacent comment body; assert URL field never contains body fragment.
5. **`pr_url` / `issue_url` / `comment_url` (T3)** — composed URLs from owner/repo/N references; no PR title / body / comment text. Sentinel injects into adjacent comment_body capture; assert URL field clean.
6. **`gh_pr_review_requested` / `_removed` (T3)** — captured fields: reviewer login (anonymized to 7-bucket per Phase 4.7.C pattern if cross-actor), PR ref, ts. No PR title / body. Sentinel walks.
7. **`gh_notification_received` (T3)** — captured: notification reason enum (review_requested / mention / state_change), source_ref. No body.
8. **All new `InboxKind` cases (T8)** — sourceURL synthesis from opaque refs only; no title/body leak. Per-kind sentinel walks `InboxSourceURLDeriver` output.

Master sentinel-injection regression test pattern: `RelayBodyLeakageTests.testEventBodyDoesNotLeakIntoPresenceState_<phase>` (continues Track-3 D1..D3 / Track-6 P1..P5 / Track-4 S1..S4 lineage).

---

## 7. Testing strategy

### 7.1 Per-phase TDD discipline (per `superpowers:test-driven-development`)

Each phase ships tests for:
- **Substrate API contract**: unit tests for new `DerivedInsights` methods (`recentLastCommit` / `weeklyMetrics`).
- **Deriver logic**: unit tests for `currentTaskIdentity()` per-IDE dispatch, `InboxSourceURLDeriver` per-ref synthesis, `ProdWhereStoppedDeriver` anchor file/line plucking.
- **Round-trip serialization**: `InsightsSnapshot` field round-trips (defaulted-init + Equatable for animation triggering).
- **Sentinel-injection regression**: privacy walkback per new payload field (see §6).
- **Integration**: fixture DB → fetch via `InsightsReader.refresh()` → assert visible block render contract.

### 7.2 Per-phase verification gates (per `superpowers:verification-before-completion`)

Each phase wraps with explicit gate checks:
1. **5/5 xcodebuild schemes** Debug build SUCCESS (LeafCore / LeafCorePrivate / Leaf / LeafAgent / LeafMCP).
2. **SPM tests green** — XCTest + Swift-Testing combined, 0 failures, recorded skipped count.
3. **`just check-tokens` 3-tier clean** — BASE + MIGRATION + RETIRED.
4. **Privacy walkback grep** — narrow scope (Phase file set), 0 hits of forbidden fields (`absolute_path` outside allowlist / `full_comment_body` / `raw_email` / `notes_body` / `email_subject` / `note_body` / `file_contents` / `raw_prompt` / `tool_input` / `tool_response` / `response_body`).
5. **Sentinel-injection test green** (per §6).
6. **HomeView.swift LOC budget** — ≤280 LOC (P6 baseline preserved).

### 7.3 Track-9 master smoke (T10 wrap)

Manual click-through on author's Mac per master spec §3 mockup:
- **TODAY**: 5 metric cells render (focused / AI ratio / sessions / switches / commits) + 4+ pills with inline counts ("Claude 14m" / "Xcode 8m" / "Linear 3" / "Slack 5") + overflow "+N more" expand.
- **YOU·NOW** `.active`: app · file / branch · LinearID / "X min focused" · intensity bars (if intensity ON).
- **YOU·NOW** other states: `.away` Resume CTA / `.inMeeting` rich / `.deepWorkFocus` workspace+LinearID.
- **WHERE STOPPED**: header · relative time / anchorFilePath:line / Last commit subject / WIP chips.
- **INBOX**: real rows (PR comment / review requested / Linear comment to me / Calendar invite declined / Xcode build failure if applicable) with severity dots and source-tap-deep-link.
- **Analytics**: WeekChipStrip + DailyFocusedChart + StreaksCard + PeakHourCallout + TopToolsCard + WoWDeltaCallout.

### 7.4 Independent code review

Each phase Stage 6 spawns `superpowers:code-reviewer` subagent. Verdict drives Track-9 forward (APPROVE / APPROVE-WITH-NITS / REJECT). REJECT → fix-bundle commit on same branch before merge.

---

## 8. Out of scope

Per scope locks:
- **Phase 5.4 WITH YOU ON THIS** — DB-backed `TeammatePresenceReader` + `presence_history` M011/M012 + WS broadcast. Phase 5.4 own track.
- **Phase 5.6 offline footer** — relay status plumbing in `InsightsSnapshot`. Phase 5.6 own.
- **C-8 Resume CTA branch-deletion staleness** — git CLI shell exec validation. v1.1.
- **C-19 localization** — `Localizable.strings` extraction. Separate localization track.
- **AI rollup substrate exposure** (M024 partial index queries) — post-Track-9 Phase 4.9 AI rollup.
- **Mode classifier impl** (`DefaultModeClassifier` against 4.7.C skeleton) — post-Track-9 Phase 4.9 separate phase.
- **Latency stats Analytics surface** (Phase 4.6.A GitHub PR cycle / Linear completion / Slack huddle) — post-Track-9 Analytics expansion. Already surfaced via Layer B drill-downs (Track-7 P4).
- **Layer C (V1.5+)** — Notion / Figma / Jira / Gmail / non-Google Calendar MCP-aggregator.
- **Layer D (V2)** — Figma plugin / VS Code extension / Chrome extension.
- **Cursor Hooks v1.7+ / Windsurf Cascade Hooks / Continue.dev hooks** — v1.1 substrate.
- **ChatGPT Desktop / GitHub Copilot / Apple Intelligence routing** — Track-6 P7 won't-list (re-evaluation triggers documented in whitepaper `privacy-security/what-we-dont-capture.md`).
- **VSCode/JetBrains AX line capture** — Electron / JBR variable AX behavior. Track-9 ships Xcode-only AX line; VSCode/JetBrains anchors fall back to file-only (line nil). Carry post-Track-9.
- **AI subagent failure detector** — Track-6 P1 M024 substrate ready, but `claude_subagent_failed` event_kind not currently emitted. Detection via transcript reading (was there SessionEnd with error). Carry post-Track-9 Phase 4.9 AI rollup.
- **Slack DM bucket routing into INBOX** — conditional on T3 verify. If substrate not emitting today, carry.
- **`recentActivity` substrate-side fetch in `InsightsReader.refresh()`** — Phase 8.8 carry C-24. T10 drops the snapshot field; LeafMCP `RecentActivityTool` keeps own reader path.

---

## 9. Carry-overs

### 9.1 Track-9 reconciles Track-8 master spec §9.1 backlog

The 24 carries enumerated in `docs/superpowers/specs/2026-05-18-track-8-home-ux-design.md` §9.1 map as follows. **18 carries resolved by Track-9** phases. **6 carries** remain post-Track-9 (per "Out of scope" above).

| Carry | Description | Track-9 resolution |
|---|---|---|
| C-1 | Hybrid surface pills | T6 |
| C-2 | Error-state last-known retention | T6 bundled |
| C-3 | ViewThatFits 5-cell wide / 2×3 narrow | T6 |
| C-4 | DateFormatter cache | already-resolved P9 |
| C-5 | LocalAppsStore reactivity | post-Track-9 (small refactor) |
| C-6 | inMeeting `ical://` deep-link | T5 |
| C-7 | a11y nested Button | already-resolved P9 (no carry) |
| C-8 | Resume CTA branch-deletion staleness | v1.1 — out |
| C-9 | YouNowMeeting substrate enrichment | T5 |
| C-10 | WithYouOnThisBlock empty CTA N count | Phase 5.4 — out |
| C-11 | Offline / stale footer | Phase 5.6 — out |
| C-12 | Row tap routes to Team tab w/o teammate selection | Phase 5.4 — out |
| C-13 | `TeammateMatch.durationSec` hardcoded | Phase 5.4 — out |
| C-14 | Search debounce / SQL re-fetch | T8 evaluate (likely defer) — **[DEFERRED T8 — cardinality stays under 14d cutoff baseline; revisit if >1000 rows/day]** |
| C-15 | `RouteCoordinator.openURL` extraction | T8 (centralize if pattern repeats) — **[DEFERRED T8 — single-callsite `NSWorkspace.shared.open` sufficient via existing InboxItemRow; centralize when 2+ blocks share]** |
| C-16 | `InboxItem.sourceURL` nil for D3-derived | T8 universal sourceURL synthesis — **[RESOLVED T8 — commits `5179865f` + Task 7 D3 enrichment moat]** |
| C-17 | filteredItems substring unit test | already-resolved P9 |
| C-18 | empty/no-match icon differentiation | already-resolved P9 |
| C-19 | Localization | out (separate track) |
| C-20 | Line 2 last-commit subject | **[RESOLVED T7 — commit `da917399` + `408a2f04`]** |
| C-21 | anchorEventId → file path:line | **[RESOLVED T7 — commit `da917399` + moat ProdInsights+RecentWhereStopped]** |
| C-22 | `formatRelative` unification | already-resolved P9 + T10 if new callsites |
| C-23 | Analytics surface real content | T9 |
| C-24 | `recentActivity` orphan drop | T10 |
| C-25 | WhereStoppedDeriver sleep/wake idle gap | **NEW post-T7 carry — own phase (T7.5 or T9-adjacent)** |

#### 9.1.C-25 — WhereStoppedDeriver sleep/wake gap (post-T7 discovery, 2026-05-21)

**Symptom:** After Track-9 T7 UI ship, manual smoke revealed `where_stopped_log` table stays empty in the common "closed laptop for 30+ min" scenario, leaving the WHERE STOPPED block stuck on empty-state copy ("No recent stop-points captured.") even when the user clearly took a real break (`ушёл в универ`-class break).

**Root cause:** `ProdWhereStoppedDeriver.derive()` (Track-1 D3) idle gate logic at `Packages/LeafCorePrivate/Sources/LeafCorePrivate/Prod/Detection/ProdWhereStoppedDeriver.swift`:

```swift
let latestTs = SELECT MAX(ts) FROM events
guard untilMs - latestTs >= 30 * 60 * 1000 else { return nil }
```

Timeline of the failing scenario:
- t=0 user closes laptop → `system_slept` event emitted → Agent process suspended.
- t=30min user opens laptop → `system_woke` event emitted immediately → `MAX(ts)` ≈ now.
- t=30min+ε `DetectorScheduler.runScheduled` ticks (every 5 min per `AgentThresholdsProd.detectorScheduledIntervalSec`) → `untilMs - latestTs ≈ 0` → idle gate FAILS → no snapshot ever appended.

**Race window where snapshot CAN fire:** user walks away from an **awake** laptop (no sleep) for 30+ min → pipeline tick during that window finds `MAX(ts)` ≈ 30 min ago → gate triggers → snapshot emitted. Closed-laptop is the dominant case in practice and it's silently broken.

**Why this is substrate gap, not T7 UI bug:** T7 verified path 4 (empty state) renders correctly when substrate returns nil. The 4-line / 3-line / 2-line population paths all work when rows exist in `where_stopped_log`. The gap is purely producer-side — `ProdWhereStoppedDeriver` doesn't account for sleep/wake semantics.

**Proposed fix directions (decide in own phase brainstorm):**
1. Treat the most recent `system_slept` event as a "synthetic idle marker" — use its ts as `latestTs` (or as a cap on `latestTs`) instead of raw `MAX(ts)`. Then `untilMs - sleep_ts` reflects the real wake gap.
2. Emit a synthesis snapshot on wake itself — detect `system_woke` arrival, look back at paired `system_slept` event, append a `where_stopped_log` row attributing the pre-sleep state if the sleep window exceeded the idle threshold.
3. Hybrid — `derive()` keeps current logic but adds a sleep-aware override: `effectiveLatestTs = (system_slept since last system_woke) ? system_slept.ts : MAX(ts)`.

**Phase ownership:** post-T7 own phase. Suggestion: T7.5 (small surgical substrate phase) OR pulled into T9 wrap depending on cadence. Requires its own spec + sentinel-injection regression test (modifying the moat deriver touches new code paths in Track-1 D3 substrate that didn't have walkback coverage before T7's reading of `doc_path`).

**Verification once fixed:** close laptop for 30+ min → open → WHERE STOPPED card automatically lit up with 4-line layout (anchor file:line + commit + WIP chips) using the pre-sleep activity context as the anchor.

**Discovered:** 2026-05-21 manual smoke during T7 Stage 8 dev-launch verification. Owner: dima. Blocks "WHERE STOPPED feels useful day-to-day" UX promise (current behavior = always empty for most users on most days).

### 9.2 P9 a11y audit carry-forwards

The 6 a11y findings from P9 polish audit subagent (master spec §9.1 last block):
- **Design-system primitive a11y audit** — distribute across T5..T9 view layers as primitives are touched.
- **WhereStoppedBlock `headerText` Timer-driven refresh** — T7 (Timer-driven or fresh-on-focus pattern).
- **TodayBlock pill label/hint semantic split** — T6.
- **InboxFilterRow selection-change announcement** — T8.
- **WithYouOnThisBlock teammateRow label/hint split** — Phase 5.4 — out.
- **Pluralization** — Localization track — out.

### 9.3 Track-9 net new carries (post-Track-9 backlog)

- **AI subagent failure detector** — Phase 4.9 AI rollup phase.
- **VSCode/JetBrains AX line capture** — post-Track-9 IDE family enrichment.
- **AI rollup + Mode classifier + Latency stats Analytics surface** — post-Track-9 Analytics expansion track.
- **`recentActivity` substrate cleanup carry-forward** — T10 already addresses; no carry.
- **Slack DM bucket routing** — conditional on T3 verify outcome.
- **`get_weekly_metrics` MCP tool** — future if AI clients request Analytics queries.
- **T5 multi-window editor accuracy** — `WorkspacePathResolver` returns the most-recently-opened VSCode/JetBrains workspace, not the currently-foregrounded one. When a user has multiple instances open and switches back to an earlier workspace, YOU·NOW renders the wrong branch / linearID until the user touches the active workspace again. Documented as a known accuracy limitation in `leaf-docs/docs/privacy-security/what-we-dont-capture.md` (Known accuracy limitations section). Fix requires per-IDE foreground-window resolution (AX-driven for VSCode-family, AppleScript-driven for JetBrains where available) — separate post-Track-9 track.

#### T8 final-review carries (2026-05-21)

- **C-26** `ProdInsights+InboxItems.swift` 795 LOC > 700 budget — split per-feeder files (`+GitHub` / `+Linear` / `+D3` / `+Local`) OR extract `synthesize*URL` static helpers to sibling `InboxURLSynthesis.swift` moat file. T10 wrap polish.
- **C-27** `queryCIFailed` `MAX(failure)` semantic ambiguity — refactor to `ORDER BY ts DESC LIMIT 1` per (repo, sha) for true "current HEAD failed count" OR doc-fix to "highest in 24h window". T10 polish.
- **C-28** `xcode://` URL scheme fictional — no registered macOS LSScheme, `NSWorkspace.shared.open(url)` fails silently. Either drop `.xcodeBuild` from `InboxSourceURLDeriver` until real deep-link mechanism lands OR document as known no-op. T10 polish or post-Track-9.
- **C-29** `queryCommentsOnMyWork` viewer_login filter anticipatory (TODO at line 112) — currently surfaces user's own outbound comments as `.commentOnMyWork`. Either rename to `.myRecentComments` semantic split OR enforce `actor.login != viewerLogin` once collector emits `actor.login` in payload. Post-Track-9 substrate enrichment.
- **C-30** Cutoff constants (`8h` build / `24h` CI / `4h` meeting / `14d` D3) hardcoded across feeders — extract to named `private static let` block for readability. T10 polish.
- **C-31** `InboxSourceContextRef.xcodeBuild(projectPath:)` parameter naming misaligned with content (substrate emits project NAME, not path) — rename to `projectIdentifier`. T10 polish (breaking public API — coordinate with consumers).
- **C-32** `liveMeeting` `started_at_ms` collision edge case (same-millisecond starts) — document as known limitation OR generate UUID-based `meeting_id` at substrate. Post-Track-9.
- **C-33** `testInboxFilterValues` missing `.alerts.rawValue` assertion. T10 polish.

---

## 10. References

- Master Track-8 spec: `docs/superpowers/specs/2026-05-18-track-8-home-ux-design.md` (§9.1 canonical backlog source).
- Track-8 P9 polish spec: `docs/superpowers/specs/2026-05-19-phase-8-9-polish.md`.
- Track-9 task statement: `.claude/shared/current-state.md` (YOU·NOW depth paragraph).
- Stage 1 Discovery inventory: 4 Explore subagent reports (this brainstorm session).
- Architecture: `.claude/shared/architecture.md`.
- Conventions / per-phase workflow: `.claude/shared/conventions.md` (one-phase-one-session, 8-stage workflow).
- ADR-010 walkback discipline: `RelayBodyLeakageTests` Track-3 D1..D3 + Track-6 P1..P5 + Track-4 S1..S4 sentinel-injection pattern.
- Phase 8.x per-phase specs (8.1 substrate + 8.3..8.9) in `docs/superpowers/specs/`.

---

## 11. Workflow per phase

Each of T1..T10 runs in a fresh Claude Code session per `.claude/shared/conventions.md` 8-stage workflow:

1. **Discovery** — Explore subagent on phase-specific substrate state.
2. **Brainstorm** — `superpowers:brainstorming` skill, one question at a time, design sections.
3. **Spec write** — `docs/superpowers/specs/2026-05-XX-track-9-T<N>-<short>.md`, self-review, user approve.
4. **Plan** — `superpowers:writing-plans` skill, atomic per-commit decomposition + explicit AC per step.
5. **Implementation** — `superpowers:test-driven-development` per step, sequential discipline.
6. **Independent review** — `superpowers:code-reviewer` subagent + `superpowers:receiving-code-review`.
7. **Verification** — `superpowers:verification-before-completion` (gates per §7.2 above).
8. **Ship** — FF merge to Track-9 collective substrate branch (opened by T1); per-phase commit `docs(shared): Track-9 T<N> landed — current-state update` (matches Track-3 D-prefix / Track-4 S-prefix / Track-6 P-prefix naming precedent, drops Track-8 "Phase 8.X" convention to avoid Track-9-internal phase numbering ambiguity).

Track-9 collective merge to main happens after T10 wrap + manual smoke per §7.3.
