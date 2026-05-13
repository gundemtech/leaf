# Activity UI Deep Expansion (deferred — reframed)

**Date:** 2026-05-11
**Status:** **Deferred / reframed (2026-05-14).** Original framing was "Track 5". After 2026-05-13 brainstorm (Anton-led) Track 5 namespace was repurposed to **Collaboration Redesign** — see `2026-05-13-track-5-collaboration-contract.md`. Activity UI surfacing of existing Track-1 D1 bodies / D3 detector hits / AX window_title / Claude Code AI events is **partially subsumed** into Track 5 / S7 (Team UI Redesign — unified feed includes detector hits and direct messages), and remaining Activity-tab-specific surfacing (multi-mode picker, drill-down rail, smart aggregation buckets) remains a future open scope — likely a separate post-Track-5 track. This document is retained for reference content; do not start implementation against it.
**Owner:** Dmitrii (deferred — re-decide owner after Track 5 ships)

## Context

Recon (2026-05-11):
- `ActivityView` (`Leaf/Views/Window/Activity/ActivityView.swift`) после Track 2 D3 rewrite на D1 substrate (LeafTab mode picker — Sessions / Raw Events).
- `ActivityRow` renders **только**: provider tag (LOCAL / LINEAR / GITHUB / SLACK / AI) + primary text + optional secondary + relative timestamp.
- Mergedcount fold into primary text (×N suffix).
- **`window_title` / `browser_url` / `body excerpts` собираются (Track-1 D1) но НЕ surface'ятся в UI** — огромный unlock потенциал.
- Track-1 D3 detector hits (`decisions` / `open_questions` / `blockers` / `where_stopped`) — есть в БД, есть MCP tools, в Activity UI не surface'ятся.
- Phase 4.7.B `presence_state` composite — есть, в UI минимально.
- AI collaboration events (Claude Code hooks) — собираются как `AI` provider tag, но без specific aggregation.

Track 5 — превращение Activity tab из read-only event log в **actionable work surface** через информационную архитектуру (IA-first), а не feature-by-feature.

## Scope

**In-scope:**
- Activity tab IA redesign + smart aggregation
- Surfacing of existing data (Track-1 D1 bodies, D2 FTS / event_links, D3 detector hits, AX window_title / browser_url, Claude Code AI events)
- Interactive detector controls (dismiss / resolve / "Resume from here")
- Track 3 + Track 4 new data surfacing (после их ship'а)
- Onboarding tour для нового UI

**Out-of-scope:**
- New collectors (Tracks 3 / 4 own this)
- Backend schema changes
- MCP tool changes
- Privacy dashboard reverse view (separate track)
- Sharing UI overhaul (Share Controls remains existing)

## Approach — IA-first sub-decomposition

3 sequential sub-phase'а. **Каждый строится на Track 2 D1 substrate** (LeafSheetLayout / LeafCard / LeafTab / LeafSection / LeafButton / LeafBadge / LeafIconLabel / LeafEmptyState / LeafMetricCard / LeafBanner) — никаких новых atomic компонентов без обоснованного дополнения substrate'а.

### UI-A — Shell redesign (информационная архитектура)

New layout:

```
┌──────────────────────────────────────────────────────────────┐
│ Today summary (3-5 LeafMetricCard adaptive grid)              │
│ "3 PRs reviewed · 1 decision · 2h deep focus · 7 commits"     │
├──────────┬────────────────────────────────┬───────────────────┤
│ Left rail│ Main stream (event list)       │ Right rail        │
│          │                                │                   │
│ Filter   │ ▸ 14:00–15:00                  │ [Event detail     │
│ chips    │   • Cursor — auth_service.swift│  drill-down       │
│ (LeafTab)│     × 12 saves                 │  for selected]    │
│          │   • Commit: "fix auth refresh" │                   │
│ Today    │     LEA-123 ↔ PR #456          │                   │
│ Yest.    │ ▸ 13:00–14:00                  │                   │
│ Week     │   • Linear: status changed     │                   │
│ ───      │     LEA-123 In Progress→Review │                   │
│ All      │ ▸ 12:00–13:00                  │                   │
│ Linear   │   • Slack: thread reply × 3    │                   │
│ GitHub   │                                │                   │
│ Slack    │                                │                   │
│ Local    │                                │                   │
│ AI       │                                │                   │
├──────────┴────────────────────────────────┴───────────────────┤
│ Insights peek: week-over-week +12% · 3-day commit streak · 14h│
└──────────────────────────────────────────────────────────────┘
```

Key elements:
- **Top hero** — Today summary strip (`LeafMetricCard` × N adaptive grid через Derived Insights Engine).
- **Left rail** — filter chips (`LeafTab`) + date scrubber (date picker w/ natural-language jump "Last Tuesday morning").
- **Main stream** — event list bucketed by hour by default; smart aggregation (повторяющиеся events за минуту склеиваются — "Cursor — `auth_service.swift` × 12 saves"); importance ranking (decisions / blockers / commits prominently; intensity ticks / focus session boundaries as quiet background sparkline gradient).
- **Right rail** — expanded detail of selected event (rich fields). On 13" Mac — degrade в sheet (`LeafSheetLayout`) instead of right rail.
- **Bottom peek** — Insights mini-strip (week-over-week delta + streaks + peak hour). Expandable в full Insights sub-tab.

**Keyboard navigation:**
- ↑/↓ — event navigation
- →/← — drill-down expand / collapse
- Cmd+F — FTS search bar focus
- Cmd+1..9 — filter chips quick-jump
- Space — toggle event selection
- Esc — close drill-down

**Privacy indicator per row:** lock icon (private only) / eye icon (shared with team) — surface ADR-020 Share Controls inline. Tap → quick toggle through to Share Controls UI.

### UI-B — Content surfacing (existing substrate, no new collectors)

**Event detail drill-down** (right rail или sheet, depending on viewport):

| Field | Source | Visibility |
|---|---|---|
| `window_title` | AX (Phase 4.10.B) | Always if collected |
| `browser_url` | AX (Phase 4.10.B) | Always if collected |
| Resolved linked target | D2 `LinearIDExtractor` + URL parsers | If recognized (Linear ID / PR / Slack channel) |
| Body excerpt | Track-1 D1 bodies | If body_kind present, truncated to ~500ch with "Show more" |
| FTS-highlighted matches | D2 `events_fts` | When search active |
| Linked events inline | D2 `event_links` | "↔ LEA-123 ↔ PR #456 ↔ Slack thread" — clickable to navigate |
| Duration / intensity sparkline | Derived from session data | If applicable |

**FTS search bar:**
- Top of main stream, sticky on scroll
- Query через D2 `events_fts` substrate
- Highlighted matches inline в event rows
- Match count badge
- Recent searches dropdown

**Per-app daily drill-down modal:**
- Tap app icon в event row → modal (`LeafSheetLayout`) с full timeline / sessions / files / windows / commits per app per day
- Aggregation through Derived Insights Engine

**Linked-group collapsed cards:**
- Events linked to same Linear ID / PR / Slack thread collapsed в один card (`LeafCard.raised`)
- Header: "LEA-123 thread: 3 commits + 2 Linear comments + 1 Slack discussion + 1 Claude Code session — 4h work"
- Expand → linear stream of constituent events

**AI sessions aggregated:**
- Claude Code hooks events grouped per session (session boundary = process start / end)
- Aggregated stats: tools called count, files touched, session duration, prompts authored count (metadata only per ADR-010)

**Detector results inline + interactive actions:**
- Track-1 D3 hits surface'ятся as `LeafBadge` on relevant events:
  - Decision: blue badge "Decision detected"
  - Open question: amber badge "Open question"
  - Blocker: red badge "Blocker"
  - Where stopped: gray badge "Where you stopped"
- **Interactive actions** per detector hit:
  - "Mark as resolved" — для open_questions + blockers; updates `*.resolved_by_event_id` / `*.resolved_at_ms`
  - "Not a decision" / "Not a blocker" — dismiss action; stored locally в новой `detector_dismissals` table (`detector_kind`, `event_id`, `dismissed_at_ms`, optional `note`); feedback signal surfaced в Settings → Detectors trust score
  - "Resume from here" — для where_stopped + open_questions; deep-link в last context (open editor at file via x-callback-url; open browser to Linear ticket; focus Slack thread). IDE support varies — implementation moat per IDE.
  - "Add note" — manual annotation to open question / decision; stored в `*.user_note` extension column

### UI-C — New-data surfacing + insights views (after Tracks 3 + 4)

- **Track 3 new event_kinds** get specific iconography + structured detail per kind (notification subject, PR review verdict color-coded, reaction emoji preview, canvas title icon).
- **Track 4 local app activity** — app-specific contextualization (Music with track context "♫ Bach · Cello Suite 1", Zoom with own meeting name, JetBrains with project name, Spaces with space switch indicator).
- **Intensity overlay** (Track 4 keystroke / mouse aggregates from S3): background heatmap layer behind app activity row ("high-intensity coding session 14:00-15:30 in Xcode" — visual density gradient).
- **Heatmap by hour view** — focus session distribution heatmap (alternative view mode, toggle via LeafTab in main stream header).
- **Timeline scroll view** — chronological scroll (alternative to bucketed default).
- **Sparklines per app row** — intensity over last 24h (mini-chart inline в bucket header).
- **Cross-provider thread viz** — collapsed linked group expanded → vertical timeline-track view (events from each provider get их own column or lane). Sankey-style overkill; skip для v1.

## Detector noise control (UI-B)

Track-1 D3 detectors могут false-positive'ить много. Mitigation:

- **Per-hit dismissal stored locally** (not shared) в новой table `detector_dismissals` (см. UI-B schema below)
- Dismissal не deletes underlying event — только hides detector badge на этом event'е
- Dismissal rate metric surfaced в Settings → Detectors — per-detector trust score (e.g. "Decision detector: 78% accepted, 22% dismissed")
- "Detector trust" preferences: toggle to disable noisy detector entirely (does not delete data, suppresses surface)
- Future enhancement (post-UI-B): detector pipeline learns не surface'ить similar pattern based on dismissal corpus (separate ML / heuristic track)

## Onboarding для нового UI

После landing'а UI-A — lightweight tour (3-4 steps) для existing users (current Activity = simple list, new = shell-based IA — концептуально новый):

1. **New shell layout intro** — "Activity has a new look. Filter chips on the left, event details on the right."
2. **Linked-group concept** — "Related events from different sources are now grouped. Tap to expand."
3. **Detector actions explain** — "Leaf flags decisions, questions, and blockers. Confirm or dismiss to teach Leaf."
4. **FTS search demo** — "Cmd+F searches across all your activity, including bodies."

**Trigger:** first launch after update с new shell (versioned via UserDefaults flag `activityUITourSeen.v2`).
**Skip:** "Dismiss" button on any step.
**Re-trigger:** Settings → Help → "Replay Activity Tour" + Cmd+? shortcut.

## Performance

1000+ events / day × full enrichment = render cost concern. Mitigation:

- **Virtual scrolling** — LazyVStack / LazyVGrid (already in use)
- **Lazy body fetch** — event detail body excerpt fetched only when drill-down opens (not on stream render)
- **Server-side aggregation** — Derived Insights Engine SQL-aggregates сразу, не в view
- **FTS query async** с loading state (`LeafBanner.info` "Searching...")
- **Detector enrichment async** with placeholder badges initially (resolves to actual hits when query completes)
- **Aggregation collapse** — повторяющиеся events за минуту склеиваются перед рендером (reduce row count)

## Schema changes

- **M016**: `detector_dismissals` table (`detector_kind TEXT NOT NULL, event_id TEXT NOT NULL, dismissed_at_ms INTEGER NOT NULL, user_note TEXT NULLABLE, PRIMARY KEY (detector_kind, event_id))`.
- **M017** (optional, UI-B): extension columns на `open_questions` / `decisions` — `user_note TEXT NULLABLE` для manual annotation.
- No changes to `events` / `events_fts` / `event_links` (substrate intact).

## Acceptance criteria (per sub-phase)

- **UI-A:** New layout renders w/ Today summary + filter chips + bucketed stream + right rail (or sheet on narrow) + Insights peek. Keyboard nav works (↑↓→← Cmd+F Cmd+1..9 Space Esc). Privacy indicators surface accurate share-state per ADR-020. Smart aggregation collapses repeats. Onboarding tour triggers on first new-shell launch.
- **UI-B:** Event drill-down shows window_title + browser_url + body excerpt (when collected) + linked events. FTS bar searches across all event kinds with highlighted matches. Linked groups collapse correctly. Detector actions persist correctly to `detector_dismissals` table + reflect в Settings → Detectors trust scores. "Resume from here" deep-link works for at least Cursor + Browser (IDE moat per app).
- **UI-C:** Track 3 + Track 4 new kinds get specific UI treatment (iconography + structured detail). Intensity overlay visible per row when Track 4 data present. Heatmap + Timeline + Sparklines views toggle correctly. Heatmap view navigable via keyboard.

## Dependencies

- Track 2 D4 substrate — landed ✅ (full atom / molecule / organism / template library)
- Track-1 D1 (bodies) — landed ✅
- Track-1 D2 (FTS + event_links) — landed ✅
- Track-1 D3 (detectors) — landed ✅
- Track 3 — needed для UI-C (new provider event kinds — ship UI-C after Track 3 D4 lands)
- Track 4 — needed для UI-C intensity overlay (ship UI-C after Track 4 S3 lands)

**UI-A + UI-B can ship BEFORE Track 3 / Track 4** — они build только на existing substrate.

## Open questions

- **OQ-1:** Right rail vs sheet for event detail на narrow screens (13" Mac MenuBar window) — right rail steals horizontal space; sheet loses context of stream. **Recommendation:** right rail on ≥1100pt, sheet on narrower.
- **OQ-2:** "Today summary" rendering — fixed 5 cards or adaptive grid (`LazyVGrid(.adaptive(minimum: 180))`)? **Recommendation:** adaptive, fold less-important metrics on narrow.
- **OQ-3:** Filter chips ordering — preserve user customization (drag-to-reorder)? Or fixed canonical order? **Recommendation:** fixed v1, customization v2.
- **OQ-4:** "Resume from here" deep-link mechanics — Cursor / VSCode have `cursor://file/path` / `vscode://file/path` schemes; Xcode supports `xed` CLI + AppleScript; JetBrains via `idea://`. **Recommendation:** per-IDE moat handler in LeafCorePrivate, fallback "Reveal in Finder" if no scheme available.
- **OQ-5:** FTS query performance на >100k events — benchmark needed. May require result pagination + LRU cache. **Recommendation:** measure в UI-B implementation session, add pagination if >200ms p95.
- **OQ-6:** Onboarding tour replay UI — Settings → Help vs Cmd+? shortcut. **Recommendation:** both, plus Settings link.
- **OQ-7:** Detector dismissal "learn" loop — out of UI-B scope, mark as future ML / heuristic track.

## Risk

- **Cognitive overload:** too much info per row → user pushback. Mitigation — strict importance-ranking + smart aggregation + opt-in detail expansion + collapsed by default.
- **Detector false-positive noise:** undermines trust. Mitigation — dismissal feedback loop + per-detector trust toggle + sensible default sensitivity.
- **Performance on dense days:** 5000+ events under heavy use. Mitigation — virtual scrolling + async enrichment + aggregation at query layer + pagination of FTS results.
- **Right rail vs sheet decision drift across viewports** — testing required across 13" / 15" / external display configs.
- **Deep-link "Resume from here" fragility** — IDE schemes change across versions; fallback "Reveal in Finder" must always work.

## Phase decomposition order

UI-A → UI-B → UI-C. Sequential. UI-A unblocks UI-B (shell needs to exist before content fills it). UI-C waits для Track 3 D4 + Track 4 S3 ship'ов. Каждый ship'ается на feature branch + acceptance gate (manual smoke на собственной системе). Collective merge после UI-C. Whitepaper sync deferred до post-UI-C collective merge (public-safe framing — "Activity surfaces D1 bodies + D2 FTS + D3 detectors as actionable IA"; implementation moat не публикуется).
