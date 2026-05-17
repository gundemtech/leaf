# Track 7 — UI Surface Polish · Design Spec

**Status:** Draft (2026-05-17). Promoted to "Active" after user review gate (Stage 3) closes.
**Stage 0 discovery:** parallel Explore agents — UI inventory + data substrate snapshot (in-session, 2026-05-17).
**Authors:** Dmitrii + Claude (brainstorm session 2026-05-17).
**Stage in 8-stage workflow:** 3 (Spec write) — implementation per-phase sessions follow approval; each phase runs `superpowers:writing-plans` → `test-driven-development` → `code-reviewer` → `verification-before-completion`.

---

## 1. Goal & scope

Bring the Native UI from "alpha.16 ships 6 deep capture surfaces under the hood but UI mostly does not show them" to a **standalone-useful glance surface that visibly delivers Track-6, Track-1 D3, and Layer B drill-down depth without an AI client**. Per `architecture.md`: Native UI is the primary surface; MCP is the bonus channel.

Fitness function:

1. **Substrate coverage.** 9 surfaces visible on Home — 6 Track-6 capture surfaces (Claude Code / Xcode / IDEs / Browsers / Zoom / Calendar) + 3 Layer B drill-downs (Linear / GitHub / Slack via LivePresenceWidget) + 1 derived "Work State" card (Track-1 D3 detection).
2. **Token-system fidelity.** 100% of new UI built on Track-2 D1 tokens (LeafCard / LeafSection / LeafBanner / LeafColor / LeafSpace / LeafType / LeafGlass). Zero hard-coded hex / pt values. `just check-tokens` passes.
3. **Read-only over substrate.** Zero new event_kinds, zero new migrations, zero new MCP tools, zero new schema. Track 7 is a UI track. Only new code in non-UI layers: ≤4 thin `DerivedInsights` protocol methods that wrap existing tables.
4. **Privacy invariants preserved.** UI renders only aggregates / buckets / structured metadata that already passes ADR-010 walkback. No raw body leakage into any new view. Existing `RelayBodyLeakageTests` continue to pass.
5. **Default OFF posture intact.** Track-6 capture surfaces remain default OFF per ADR-020. Home does not silently surface anything that wasn't enabled. Disabled surface = compact row with explicit `[Enable]` CTA → Settings deep-link.
6. **Smoke verified.** Per-phase acceptance gate (§13) on author's Mac before each phase's collective merge.

**In scope:** Home surface section (compact rows + full cards), generic detail screen scaffold, 6 Track-6 detail screens, 3 Layer B detail screens, 1 Work State card + detail, `filesTouched` integration into Today section, Settings deep-link plumbing, navigation routing, empty state matrix, HIG review, acceptance smoke.

**Out of scope (hard exclusion list):**

- New event_kinds, migrations, or schema changes.
- New MCP tools (existing 15 are sufficient).
- AI narrative / "describe my week in words" (v1.1 BYOK track).
- Phase 4.9 Derived Modes / Mode Classifier UI (separate roadmap).
- Activity tab changes (filters / search / row redesign). Stays as-is.
- Settings UI changes (toggles all already shipped).
- Team / Org / Profile / MenuBar tab changes.
- Mobile (iOS) UI — Track 8+.
- Drag-and-drop card reorder (deferred to v1.1).
- Custom date-range picker on detail screens (deferred to v1.1).
- Full-text search UI over `events_fts` (separate feature).
- Cross-provider thread visualization (`get_cross_provider_thread` MCP tool surfacing) — `[Linked thread →]` link rendered as plain text only in Work State detail rows; no graph view.
- Layer A AppleScript apps (Music / Notes / Mail / Reminders / etc.) Home aggregation cards (Activity tab continues to render them).
- Intensity / system observer aggregation cards (privacy-low-value as glance).
- Per-row drill-down on individual Activity events. Activity remains read-only stream.

---

## 2. Information architecture (locked from brainstorm)

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **Nav IA** | Home as growing dashboard (no new tab) | A1 — keep sidebar at 7 entries, all glance on one scroll surface |
| **Drill-down** | NavigationStack push on detail pane | A2 — macOS HIG-native, scales for nested levels (e.g. Claude Code → session) in v1.1, sidebar persists |
| **Empty-state pattern** | Compact disabled row + full enabled card | A3 — discovery preserved, no dead pixels, unified paradigm across all 6 Track-6 surfaces |
| **Detail time window** | `[Today][Week*][Month]` LeafTab, default Week | A4 — stable at any hour of day, knowable analytics pattern, DerivedInsights API takes `DateInterval` |
| **Surface card order** | Fixed by capture-volume heuristic, enabled-first sub-grouping | A5 — predictable, simple static array, visible payoff on enable |
| **Card template** | Headline metric + sub-stats + 7-day spark + chevron | A6 — predictable visual grammar across 9 surfaces |
| **Activity tab impact** | Out of scope | A7 — per-surface insights live on detail screens; Activity stays time-stream |
| **Phasing** | P1 foundation + Claude Code, P2-P6 per surface, P7 Work State, P8-P10 Layer B, P11 polish | A8 + audit additions — 11 phases, one session each per CLAUDE.md |
| **Work State surface** | New card between Today and Surfaces sections, always visible | Audit addition — Track-1 D3 substrate is derived not capture, no enable toggle, always on |
| **Layer B drill-downs** | LivePresenceWidget columns become tappable → push detail screens | Audit addition — symmetry with Track-6 surfaces, reuse detail scaffold from P1 |
| **filesTouched in Today** | Add as +1 inline metric in existing Today section | Audit addition — fold into P1 foundation, ≤10 LOC |

---

## 3. Home layout (post-Track 7)

```
┌─ Home (detail pane, NavigationStack root) ───────────────────┐
│  Hero (active session)                              │ unchanged
│  LivePresenceWidget                                 │ NOW CLICKABLE per column
│    [GitHub ▸] [Linear ▸] [Slack ▸]                  │ (P8/P9/P10)
│  Today                                              │ + filesTouched (P1)
│    focus hours · streak · ai% · peak · switching ·  │
│    files touched (NEW)                              │
│  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ │
│  Work State                              ▸          │ NEW (P7)
│    {N open questions · M blockers}                  │
│    Last decision: "{excerpt, max 60 ch}"            │
│  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ │
│  Surfaces                                           │ NEW section (P1)
│    Enabled cards (full, ordered by heuristic):      │
│      ┌─ Claude Code            ▸ ─┐                 │
│      │  2.1M tokens               │                 │
│      │  47 tool calls · 3 sessions│                 │
│      │  ▒██▒████▒▒█ (7d spark)    │                 │
│      └────────────────────────────┘                 │
│      [Xcode if ON]                                  │
│      [IDEs if ON]                                   │
│      [Browsers if ON]                               │
│      [Zoom if ON]                                   │
│      [Calendar if ON]  ← stays disabled-only        │
│    Disabled compact rows (remaining surfaces):      │
│      ⎮ {icon} {Name}    Off    [Enable / Connect]   │
│      ...                                            │
│  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ │
│  Recent Sessions                                    │ unchanged
└─────────────────────────────────────────────────────┘
```

**Surface ordering (static array, defined in `SurfaceCatalog.swift`):**

```swift
public enum HomeSurface: String, CaseIterable {
    case claudeCode    // 1 — highest volume (AI coding flow)
    case xcode         // 2 — primary dev IDE on macOS
    case ides          // 3 — secondary dev IDEs
    case browsers      // 4 — research / docs
    case zoom          // 5 — async-light
    case calendar      // 6 — atomic state events
}
```

Enabled surfaces render first (full cards), then disabled (compact rows) in the same `HomeSurface.allCases` sub-order. Implementation: partition `allCases` by `isEnabled` predicate; render two `ForEach` blocks.

---

## 4. Surface card contract

### 4.1 Generic component — `SurfaceCard`

A new D1 organism. Lives in `Leaf/UI/Organisms/SurfaceCard.swift` (or `Packages/LeafCore/Sources/LeafCore/UI/...` if it generalises). Uses `LeafCard(variant: .raised, padding: .regular)` as its container. Liquid Glass NOT used (6 stacked glass surfaces = visual fatigue + perf cost on Intel macs).

```swift
public struct SurfaceCard<Spark: View>: View {
    let surface: HomeSurface       // controls icon + accent
    let headline: String           // e.g. "2.1M tokens"
    let subStats: [String]         // 1-3 entries, joined " · "
    let spark: Spark               // 7-day mini chart (Swift Charts)
    let onTap: () -> Void          // triggers NavigationLink

    // Layout:
    //   HStack { LeafIcon(surface.icon) · headline + subStats · spark · chevron }
    //   tap target = entire row, button style .plain
    //   accessibility label = "{name}: {headline}, {subStats joined}"
}
```

### 4.2 Compact disabled row — `SurfaceRow`

For not-yet-enabled surfaces. Single-line row.

```swift
public struct SurfaceRow: View {
    let surface: HomeSurface
    let action: SurfaceAction      // .enable(deepLink), .connect(deepLink)

    // Layout:
    //   HStack { LeafIcon(surface.icon, .muted) · name · spacer · "Off" Pill ·
    //            LeafButton(.secondary, size: .sm) }
    //   tap target = button only (row not tappable)
    //   accessibility label = "{name}, capture is off, double tap to enable"
}
```

### 4.3 Per-surface payload contract

| Surface | Headline (today) | Sub-stats (joined " · ") | Spark (7d daily) | Data source | Capture gate |
|---------|------------------|--------------------------|------------------|-------------|--------------|
| **Claude Code** | `{N}M tokens` | `{N} tool calls`, `{N} sessions` | daily token sum | `aiActivityBreakdown(period:)` + raw `claude_tokens_used` sum-by-day | AI Tools toggle (Settings → AI Tools) |
| **Xcode** | `{N} builds` | `{N} tests passed`, `{N} failures` | daily build count | events `signal_type=action AND event_kind LIKE 'xcode_build_%'` grouped-by-day | Local Apps → Xcode |
| **IDEs** | `{N} workspaces` | `{N} files`, `{N} sessions` | daily distinct workspace count | events `event_kind IN ('vscode_workspace_opened','jetbrains_recent_project_observed', ...)` | System Observers → IDEs |
| **Browsers** | `{N} pages` | `{N} domains`, `{topDomain}` | daily nav count | events `event_kind LIKE '%_tab_navigated'` (Safari/Chrome/Arc) | Privacy → Browser Allow-list + System Observers |
| **Zoom** | `{N} meetings` | `{Hh Mm} in calls` | daily meeting count | events `event_kind='zoom_meeting_started'` + sum `duration_ms` | Local Apps → Zoom |
| **Calendar** | `{N} events` | `{Hh Mm} focus blocks`, `{N} OOO` | daily focus minutes | `google_calendar_*` events | Connections → Google Calendar OAuth (dormant) |

**Time-zero handling:** if Today values are all zero AND the surface IS enabled — render the card with a thin `LeafBanner.info` strip inside: "No activity captured today yet." Spark still renders (could show last 7d activity). Card stays in enabled position (top group). This avoids the surface "jumping" between enabled-with-data and enabled-without-data positions during slow days.

### 4.4 Sub-stats nil-safety

Each surface payload computes sub-stats with `nil`-guards: if a count is 0, omit that fragment rather than rendering "0 sessions". If all sub-stats degenerate, fall back to single-fragment headline + spark only (no second line). `RecentEvents.empty` does NOT degrade headline.

---

## 5. Detail screen contract

### 5.1 Generic scaffold — `SurfaceDetailLayout`

Reusable layout for all 9 detail screens. Lives in `Leaf/UI/Templates/SurfaceDetailLayout.swift`.

```
┌─ Detail (pushed onto NavigationStack) ────────────────────────┐
│  Toolbar: ‹ Home  ·  [Today][Week*][Month] LeafTab            │ ← P1
│  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ │
│  Section 1: Headline                                          │
│    Large metric · Δ vs prev period (if available)             │
│  Section 2: Primary chart (Swift Charts, ~120pt height)        │
│    Today: hourly distribution                                 │
│    Week: daily bar chart                                      │
│    Month: daily line chart                                    │
│  Section 3: Aggregates (surface-specific content slot)        │
│    LeafSection wrapping LeafCard with per-surface breakdown   │
│  Section 4: Recent events (surface-filtered, max 50)          │
│    LeafSection wrapping LeafCard with ActivityRow components  │
│  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ │
│  Empty state (per range): LeafEmptyState if all-zero          │
└───────────────────────────────────────────────────────────────┘
```

API:

```swift
public struct SurfaceDetailLayout<Aggregates: View>: View {
    let title: String
    let headline: DetailHeadline    // {value, trend?}
    let chart: SurfaceChart         // generic, dispatches on range tab
    let aggregates: Aggregates      // surface-specific slot
    let recentEvents: [ActivityFeedEntry]  // capped at 50
    @State private var range: DetailRange = .week
    // emits range-change → re-queries upstream view-model
}
```

Range tabs use existing `LeafTab` molecule. Range value flows up to view-model which re-issues Derived Insights queries with the matching `DateInterval` (today midnight → now; this week Mon → now; this month 1st → now).

### 5.2 Per-surface Section 3 content

| Surface | Aggregates section content | Derived Insights / SQL source |
|---------|---------------------------|-------------------------------|
| **Claude Code** | Tokens by model · Top tools (top 5 with call count) · Top projects (top 3 from `agent_id` workspace path) · Subagent activity (count by `agent_type`) | `aiActivityBreakdown(period:)` extended; raw events for top-N rollups |
| **Xcode** | Build success rate (pass/fail ratio) · Tests passed/failed total · Schemes used (top 3) · Run destinations used (top 3 enum buckets) | events filter + GROUP BY payload fields |
| **IDEs** | Top workspaces (top 5) · Distinct file count · JetBrains products active (count by bundle) | events filter + GROUP BY |
| **Browsers** | Top 5 domains by page count · Distinct domains count · Bookmarks delta · Per-browser breakdown (Safari/Chrome/Arc) | events filter + GROUP BY |
| **Zoom** | Total time in calls · Average meeting duration · Linked vs ad-hoc count (`zoom_meeting_calendar_linked` join) | events + duration sum |
| **Calendar** | Focus block hours · OOO days · Working location distribution (office/remote/etc) · Linked Zoom meetings count | `google_calendar_*` events + payload extraction |
| **Linear** | By-project (top 5) · By-status (started/completed/canceled/reopened) · Completion rate · `linearTransitions` summary | `linearActivity(period:)` + `linearTransitions(period:)` + `linearCompletionRate(period:)` |
| **GitHub** | PRs awaiting review · Open PRs · Reviews submitted · By-repo (top 5) · By-kind (push/PR/issue/release) | `githubActivity(period:)` + `ReviewActivityInsights` |
| **Slack** | Messages by channel (top 5) · Huddle hours · Mentions count · Files shared | `slackActivity(period:)` |
| **Work State** | Decisions / Open Questions / Blockers / Where Stopped — see §6 | NEW `DerivedInsights` methods (see §9) |

### 5.3 Section 4 recent events

Re-uses `ActivityRow` (Track-2 D3 component). Filtered by source matching the surface. Max 50 rows (no pagination in v1.0 — if user wants full history, they use Activity tab with provider filter).

Filter contract (per surface):
- Track-6 capture surfaces: `event_kind` prefix match (`claude_%`, `xcode_%`, `vscode_%` ∪ `jetbrains_%`, `safari_%` ∪ `chrome_%` ∪ `arc_%`, `zoom_%`, `google_calendar_%`)
- Layer B surfaces: `source` field match (`linear` / `github` / `slack`)
- Work State: a hybrid — rows come from `decisions` / `open_questions` / `blockers` / `where_stopped_log` tables directly (see §6.4), NOT from `events` table

### 5.4 Trend Δ vs prev period

Each detail screen shows trend delta in the headline area: `"2.1M tokens  ↑ +12% vs prev"`. Computed by querying same metric over `prev period` (e.g. Week tab compares to prior 7d). Falls back gracefully:

- If prev period had 0 data → no Δ (omit trend line entirely)
- If prev period equal → "→ unchanged"
- If `weekOverWeekDelta()` Derived Insights stub returns nil (currently always) — trend uses a one-off SQL diff at view-model level instead of the global stub. Stub function untouched (out of scope per §1).

---

## 6. Work State card + detail (NEW, Track-1 D3 surface)

### 6.1 Card on Home

Always visible (no capture toggle — D3 detection runs as scheduled detectors always). Positioned between Today and Surfaces sections.

```
┌─ Work State                              ▸ ──────────┐
│  3 open questions · 1 blocker                       │   ← headline
│  Last decision: "use SQLite WAL for cross-process"  │   ← sub-line (60 ch + …)
└─────────────────────────────────────────────────────┘
```

**Headline composition rules:**

- Zero state: `"All clear"` (single fragment, neutral tone, LeafColor.text.secondary)
- N open questions only (no blockers, no decisions): `"{N} open question{s}"`
- M blockers only: `"{M} blocker{s}"`
- Both: `"{N} open question{s} · {M} blocker{s}"`
- Sub-line: most recent decision excerpt (max 60 chars, ellipsis if truncated). LeafColor.text.tertiary if older than 7d.

### 6.2 Detail screen

Same `SurfaceDetailLayout` scaffold, BUT:

- No primary chart (categorical data, not time-series). Section 2 replaced with second-level `LeafTab`: `[Decisions][Questions][Blockers][Where Stopped]`.
- Section 3 (Aggregates) — counts summary across the active tab.
- Section 4 (Recent) — list of items from the selected sub-tab.

```
┌─ Work State detail ──────────────────────────────────┐
│  Toolbar: ‹ Home  ·  [Today][Week*][Month]          │
│  Headline: 3 open questions · 1 blocker · 12 decisions│
│  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ │
│  [Decisions] [Questions*] [Blockers] [Where Stopped]│   ← second LeafTab
│  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ │
│  Aggregates (per active tab):                       │
│    Questions tab: Open count · Avg age · Top sources│
│  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ │
│  List (per active tab):                             │
│    ┌─ Question row ───────────────────────────────┐ │
│    │  "Should we use AES-GCM or ChaCha20?"        │ │
│    │  opened 2h ago · slack thread → unanswered   │ │
│    └─────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────┘
```

### 6.3 Per-sub-tab content

| Sub-tab | Aggregates row | List item shape | Cap |
|---------|----------------|-----------------|-----|
| Decisions | Count · Avg confidence | `excerpt · "{topic keywords joined}" · detected ago` | top 30 by `detected_at_ms DESC` |
| Questions | Open count · Avg age | `excerpt · alternatives count · context ref` | top 30 — open partition first by `opened_at_ms DESC`, then resolved partition by `resolved_at_ms DESC`; together capped at 30 |
| Blockers | Open count · Open by target_kind | `excerpt · target_kind: target_ref · open age` | top 30 — open partition first by `started_at_ms DESC`, then resolved partition by `resolved_at_ms DESC`; together capped at 30 |
| Where Stopped | Snapshot count · Last snapshot age | `excerpt · wip_signals chips · generated ago` | top 20 by `generated_at_ms DESC` |

Cross-linked references (Slack thread / Linear issue / GitHub PR) render as plain text affordance `"→ {ref}"` only — no graph view, no clickable navigation in v1.0. Tooltip on hover shows full reference. Future cross-thread visualization (using `get_cross_provider_thread` MCP) deferred.

### 6.4 Data source

Reads directly from D3 tables; no `events` table involved.

```sql
-- Card headline counts
SELECT COUNT(*) FROM open_questions WHERE resolved_by_event_id IS NULL;
SELECT COUNT(*) FROM blockers WHERE resolved_at_ms IS NULL;
SELECT excerpt FROM (
  SELECT excerpt, detected_at_ms FROM decisions ORDER BY detected_at_ms DESC LIMIT 1
);

-- Detail sub-tab lists (see §6.3 for column shapes)
```

These four queries become four new methods in `DerivedInsights` protocol (see §9).

---

## 7. Layer B drill-down — LivePresenceWidget click → detail

### 7.1 Widget change

`LivePresenceWidget` (existing 3-column display of GitHub / Linear / Slack live state) becomes tappable per column. The widget itself remains unchanged visually — only adds tap target on the column.

Click → push `LinearDetailScreen` / `GitHubDetailScreen` / `SlackDetailScreen` onto NavigationStack. Same `SurfaceDetailLayout` scaffold as Track-6 detail screens.

Affordance: hover/focus on a column shows subtle chevron in column header area (existing pattern; `LeafColor.text.tertiary` chevron).

### 7.2 Reusing the scaffold

Each Layer B detail screen is structurally identical to a Track-6 detail screen:

- Toolbar with range tabs
- Headline + trend
- Primary chart (Swift Charts daily activity)
- Aggregates (per-surface content per §5.2)
- Recent events (filtered by `source`)

Implementation savings: P8-P10 each adds one View file (~150 LOC) reusing scaffold. Aggregates section uses already-implemented Derived Insights breakdown functions (`linearActivity` / `githubActivity` / `slackActivity` / `linearTransitions` / `ReviewActivityInsights`).

### 7.3 Subset of accept-states

For GitHub specifically: if `GitHubScopesReader.connectedScopeOutdated` triggers (Track-3 D2 partial connectivity), the detail screen shows the same `LeafBanner.warning` as Connections tab does today. Tap-through reauth flow opens. Banner is dismissable per-launch via AppSessionID (existing pattern, copy from `HomeView`). Same for Slack scopes drift.

---

## 8. Empty state matrix

| Surface | OFF (capture not enabled) | ON + zero today | ON + zero all-time | Provider reauth needed |
|---------|--------------------------|-----------------|--------------------|-----------------------|
| Track-6 (any of 6) | Compact row + `[Enable]` deep-link | Full card + inline info banner "No activity captured today yet" + spark from 7d if any | Full card + headline "0 today" + spark line (zero baseline) | n/a (local) |
| Calendar (P6) | Compact row + `[Connect]` deep-link to OAuth | Same as above | Same | OAuth state machine surfaces via existing Connections row + Home banner |
| Layer B (Linear/GH/Slack) | n/a (always-connected providers in MVP; if disconnected, LivePresenceWidget shows existing "Connect in Connections" message) | LivePresenceWidget column shows live count = 0; detail screen surfaces 0 metrics gracefully | Same as Today | GH/Slack scope drift → warning banner in detail screen header (per §7.3) |
| Work State | n/a (always on) | Card shows "All clear" headline | Card shows "All clear" headline | n/a |

**Implementation contract:** `SurfaceCardViewModel` exposes a `state: SurfaceCardState` enum — `.disabled`, `.enabledLoading`, `.enabledEmpty`, `.enabledZeroToday`, `.enabledPopulated`, `.error`. View dispatches on this enum. No silent empty states — every surface ALWAYS renders something user-meaningful.

---

## 9. Derived Insights coupling (new methods + existing reuse)

### 9.1 New `DerivedInsights` protocol methods (P7 introduces these for Work State)

```swift
public protocol DerivedInsights {
    // ... existing 22 methods ...

    // NEW for Track 7 P7 (Work State surface)
    func recentDecisions(period: DateInterval, limit: Int) throws -> [Decision]
    func openQuestions(period: DateInterval) throws -> [OpenQuestion]
    func openBlockers() throws -> [Blocker]   // open = active; no period (life-of-blocker)
    func recentWhereStopped(limit: Int) throws -> [WhereStoppedSnapshot]
}
```

Implementation lives in `LeafCorePrivate/Prod/Insights/ProdInsights+WorkState.swift` (gitignored impl bodies per implementation moat rules — these contain SQL bodies). Public protocol surface is the four signatures above + their return types in `LeafCore/Sources/LeafCore/Insights/`.

Stub fallback in `DerivedInsights+StubExtensions.swift`:

```swift
public extension DerivedInsights {
    func recentDecisions(period: DateInterval, limit: Int) throws -> [Decision] { [] }
    func openQuestions(period: DateInterval) throws -> [OpenQuestion] { [] }
    func openBlockers() throws -> [Blocker] { [] }
    func recentWhereStopped(limit: Int) throws -> [WhereStoppedSnapshot] { [] }
}
```

So a fresh DB / no-D3-detections-yet state surfaces "All clear" naturally without throwing.

### 9.2 New return types (public, in LeafCore)

```swift
public struct Decision: Equatable, Hashable, Sendable {
    public let id: Int64
    public let excerpt: String          // ADR-010 capped at <500 chars upstream
    public let topicKeywords: [String]
    public let confidence: Double       // 0.0 ... 1.0
    public let detectedAtMs: Int64
    public let sourceEventId: Int64?
}

public struct OpenQuestion: Equatable, Hashable, Sendable {
    public let id: Int64
    public let excerpt: String
    public let alternatives: [String]
    public let contextRef: ContextRef?  // Slack thread / Linear issue / GitHub PR
    public let openedAtMs: Int64
    public let resolvedAtMs: Int64?     // nil = open
    public let resolvedBySourceEventId: Int64?
}

public struct Blocker: Equatable, Hashable, Sendable {
    public let id: Int64
    public let targetKind: BlockerTargetKind     // linearIssue, githubPR
    public let targetRef: String
    public let blockerKind: BlockerKind          // patternBlockedOn, linearStuck
    public let excerpt: String
    public let startedAtMs: Int64
    public let resolvedAtMs: Int64?
}

public struct WhereStoppedSnapshot: Equatable, Hashable, Sendable {
    public let id: Int64
    public let generatedAtMs: Int64
    public let anchorEventId: Int64?
    public let excerpt: String
    public let wipSignals: [String]    // chips for UI render
}

public enum ContextRef: Equatable, Hashable, Sendable {
    case slackThread(ts: String)
    case linearIssue(ref: String)
    case githubPR(ref: String)
}
```

### 9.3 Existing Derived Insights reuse (no changes needed)

| Surface | Functions consumed |
|---------|--------------------|
| Today section (P1 +filesTouched) | `filesTouched(period:)` — wire to Today section row |
| Claude Code detail (P1) | `aiActivityBreakdown(period:)` + raw `claude_tokens_used` extraction at view-model |
| Xcode detail (P2) | events queries (no Derived Insights function for Xcode — view-model holds SQL helpers) |
| IDEs detail (P3) | events queries |
| Browsers detail (P4) | events queries |
| Zoom detail (P5) | events queries (sum of `duration_ms` payload) |
| Calendar detail (P6) | events queries (payload extraction); deferred until GCP |
| Linear detail (P8) | `linearActivity(period:)` + `linearTransitions(period:)` + `linearCompletionRate(period:)` |
| GitHub detail (P9) | `githubActivity(period:)` + `getReviewActivity(period:)` (from `ReviewActivityInsights`) |
| Slack detail (P10) | `slackActivity(period:)` |

### 9.4 Stub-handled gracefully

`peakProductivityHour() -> Int?` returns nil → Today section silently hides the row (existing). `weekOverWeekDelta() -> Double?` returns nil → trend Δ on detail screens computed by view-model directly (per §5.4), global stub remains nil. `activeDaysInRow() -> Int` returns 0 → "0d streak" never shown (Today already conditional on > 0). No spec change required — preserve existing behavior.

### 9.5 New view-model SQL helpers (P2-P6 each)

Per-surface detail screens that lack a Derived Insights wrapper (Xcode, IDEs, Browsers, Zoom, Calendar) read events directly via view-model methods. These helpers live in `LeafCorePrivate/Prod/UI/<Surface>DetailViewModel.swift` (gitignored — SQL bodies) and expose public structs in `LeafCore` for testability.

```swift
// Example (Xcode):
public struct XcodeDetailMetrics: Equatable, Sendable {
    public let buildCount: Int
    public let testsPassedCount: Int
    public let failuresCount: Int
    public let topSchemes: [(name: String, count: Int)]
    public let topDestinations: [(bucket: RunDestinationBucket, count: Int)]
    public let dailyBuilds: [(day: Date, count: Int)]
}
```

These types live in public LeafCore; SQL impl in private. Substrate-only changes.

---

## 10. Settings deep-linking

Each `[Enable]` / `[Connect]` button in compact disabled rows deep-links to the relevant Settings section. Implementation: NavigationStack route extension that targets specific sub-section.

| Surface | Deep-link target |
|---------|------------------|
| Claude Code | Settings → AI Tools (existing section) |
| Xcode | Settings → Local Apps → Xcode row |
| IDEs | Settings → System Observers → IDEs sub-section |
| Browsers | Settings → System Observers → Browsers (and link to Privacy → Browser Allow-list) |
| Zoom | Settings → Local Apps → Zoom row |
| Calendar | Connections → Google Calendar (OAuth-flow, not Settings) |

**Routing mechanism:** new `AppRoute` enum value `.settings(section: SettingsSection, sub: SettingsSubsection?)` consumed by RootView's coordinator. Existing onboarding deep-links already use a similar pattern — extend, don't reinvent. Buttons emit `route(.settings(.localApps, sub: .xcode))` via environment-injected coordinator.

---

## 11. HIG checklist (macOS)

- Sidebar persists across all drill-downs — no full-screen takeover.
- Range tabs follow standard control bar height (28pt).
- LeafCard padding remains `.regular` (16pt) for all surfaces — no per-surface overrides.
- Card spacing in Surfaces section: 12pt vertical (LeafSpace.md).
- Compact row height: 36pt (matches LeafListRow standard).
- Hover affordance on tappable cards: subtle elevation lift (LeafElevation.raised → +1pt shadow) + cursor pointer.
- Keyboard nav: Tab cycles through enabled cards + compact rows; Return triggers tap. Escape on detail screen → pop NavigationStack.
- Reduce Motion: spark sparkline animation respects `accessibilityReduceMotion`; range tab transitions use opacity-only fade when reduce-motion is ON.
- Reduce Transparency: glass surfaces (none on cards by design) → no-op; banners use solid `LeafColor.surface.inset` fallback.
- Dynamic Type / Large Text: card headline scales via `LeafType.title.medium`; sub-stats via `LeafType.body.regular`. Compact row text wraps at 2 lines max before truncating; trailing button width fixed.
- Localizable strings: all new copy via `Localizable.strings` keys prefixed `home.surface.*`, `home.work_state.*`, `detail.*`. No hardcoded English in views.
- Color contrast: disabled compact row uses LeafColor.text.tertiary on LeafColor.surface.raised — WCAG AA verified via existing token contrast registry (Track-2 D1 baseline).
- Accessibility labels: per §4.1 / §4.2 — verbose labels include "{name}: {headline}, {subStats}" / "{name}, capture is off, double tap to enable".

---

## 12. Phasing breakdown

11 phases. Each is one Claude session per CLAUDE.md "Одна phase = одна сессия". Each phase ends with collective merge-pending state (does NOT merge to main until Track 7 acceptance gate clears in P11).

### P1 — Foundation + Claude Code (largest phase, sets templates)

**Scope:**
- New types: `HomeSurface` enum, `SurfaceCatalog` static array, `SurfaceCardState` enum.
- New components: `SurfaceCard<Spark>`, `SurfaceRow`, `SurfaceDetailLayout<Aggregates>`.
- New section on Home: `SurfacesSection` (renders enabled cards + disabled rows, partitioned).
- `filesTouched` wire-up into existing `TodayBlock`.
- AppRoute extension for Settings deep-linking; coordinator plumbing.
- NavigationStack scaffolding on Home detail-pane root.
- Claude Code: `ClaudeCodeSurfaceCardViewModel` + `ClaudeCodeDetailScreen` + `ClaudeCodeDetailViewModel` (full vertical slice — template established).
- Token additions: 0 (use existing D1 only).

**Acceptance per P1 spec §13:** A. compact rows render when AI Tools toggle OFF; B. enabling AI Tools causes Claude Code to promote to full card within 5s; C. Click Claude Code card → detail screen, back → Home with scroll preserved; D. Today/Week/Month tabs re-query and animate; E. `[Enable]` button deep-links to Settings → AI Tools.

### P2 — Xcode card + detail

**Scope:** `XcodeSurfaceCardViewModel`, `XcodeDetailScreen`, `XcodeDetailViewModel`, `XcodeDetailMetrics` SQL helper, `Xcode` entry in SurfaceCatalog. Reuses P1 scaffolds. Adds Settings → Local Apps → Xcode deep-link route. No new component types.

### P3 — IDEs card + detail

**Scope:** IDEs view-model + screen + SQL helper. Per-fork breakdown logic (group VSCode-family parsers + JetBrains rows; aggregate workspace count across forks). System Observers → IDEs deep-link route.

### P4 — Browsers card + detail

**Scope:** Browsers view-model + screen + SQL helper. Per-domain allow-list awareness — detail screen aggregates respect granularity rule (L4 vs L3 vs domain-only) per per-domain config. Cross-link to Privacy → Browser Allow-list section.

### P5 — Zoom card + detail

**Scope:** Zoom view-model + screen + SQL helper. Aggregate `duration_ms` for "in calls" headline. Joined-vs-ad-hoc count via `zoom_meeting_calendar_linked` event presence. Settings → Local Apps → Zoom deep-link.

### P6 — Calendar card placeholder (no detail until GCP)

**Scope:** Calendar compact-row only. `[Connect]` button → OAuth flow (existing). Detail screen view-model + screen scaffolded but currently empty (renders LeafEmptyState until events flow). When GCP clears, P6.B (deferred) wires aggregates.

### P7 — Work State card + detail (Track-1 D3 surface)

**Scope:**
- 4 new `DerivedInsights` protocol methods (per §9.1) + stub extensions + private prod impls.
- 4 new public structs `Decision` / `OpenQuestion` / `Blocker` / `WhereStoppedSnapshot` / `ContextRef`.
- Work State card on Home (always visible, no toggle).
- Work State detail screen with second LeafTab (`[Decisions][Questions][Blockers][Where Stopped]`).
- Per-sub-tab list view (re-uses LeafListRow base, custom row shape per sub-tab).
- Empty state per sub-tab.

### P8 — Linear detail (via LivePresenceWidget click)

**Scope:** Make LivePresenceWidget Linear column tappable. New `LinearDetailScreen` reusing SurfaceDetailLayout. Aggregates section consumes `linearActivity(period:)` + `linearTransitions(period:)` + `linearCompletionRate(period:)`.

### P9 — GitHub detail (via LivePresenceWidget click)

**Scope:** GitHub column tappable. New `GitHubDetailScreen`. Aggregates from `githubActivity(period:)` + `ReviewActivityInsights`. Reauth banner on scope drift (per §7.3).

### P10 — Slack detail (via LivePresenceWidget click)

**Scope:** Slack column tappable. New `SlackDetailScreen`. Aggregates from `slackActivity(period:)`. Reauth banner on scope drift.

### P11 — Polish & acceptance gate

**Scope:**
- HIG checklist sweep (§11) per all 9 detail screens + Home.
- Manual smoke A–G per surface (per §13).
- Animation tuning — range tab transitions, card promote/demote animations, spark redraw smoothing.
- Empty state copy review (final localization pass).
- `just check-tokens` 3-tier verification.
- Performance sanity: ensure SurfacesSection re-renders are scoped (no whole-Home re-layout on single-card update).
- Track 7 acceptance gate: smoke matrix from §13 clears on author's Mac.
- Collective merge of P1-P10 stack into main + whitepaper sync per public-safe framing (§14.2).

---

## 13. Acceptance smoke matrix

### 13.1 Per-phase smoke (run on author's Mac, single session)

Each phase's smoke is verified before its merge-pending state. All gates run at P11 again as integration.

| Phase | Smoke checks |
|-------|--------------|
| P1 | A. Default Home renders 6 compact rows (none enabled). B. Enable Claude Code via Settings → Home updates within 5s. C. Click Claude Code card → detail. D. Range tabs Today/Week/Month re-query. E. `[Enable]` deep-links to Settings → AI Tools. F. Today section shows files touched count. G. Back from detail preserves Home scroll. |
| P2 | Same A–G with Xcode (Local Apps → Xcode deep-link). Build a project → card headline updates within 1 tick. |
| P3 | Same A–G with IDEs. Open VSCode workspace → card workspace count increments. |
| P4 | Same A–G with Browsers. Browse 3 tabs on allow-listed domain → card page count increments. Detail screen respects per-domain granularity. |
| P5 | Same A–G with Zoom. Join+leave a Zoom meeting → card "in calls" updates. |
| P6 | Only A + E + (no detail tap). Compact row always shows, `[Connect]` deep-links to OAuth (which is dormant — verify CTA disabled visually + tooltip explains GCP gate). |
| P7 | A. Work State card visible (no toggle). B. With test fixtures: 3 open Qs + 1 blocker → headline renders. C. Click → detail. D. Sub-tab switching works. E. Zero-state shows "All clear". F. Resolved questions appear below open. G. ContextRef text "→ {ref}" rendered. |
| P8 | A. Linear column in LivePresenceWidget shows chevron on hover. B. Click → LinearDetailScreen. C. Range tabs work. D. Aggregates section shows by-project / by-status. E. Back returns to Home with scroll preserved. |
| P9 | Same A–E with GitHub. F. Trigger scope drift → warning banner appears in detail header. |
| P10 | Same A–E with Slack. F. Same scope drift → banner. |
| P11 | Full integration: all 9 surfaces visible, all detail screens reachable, all range tabs work, HIG checklist passes, `just check-tokens` clean, `xcodebuild` 5/5 schemes green. |

### 13.2 Track-wide smoke (P11 integration only)

- **AC-1** Fresh install (no capture enabled, no Layer B connected): Home renders 6 compact rows + Work State "All clear" + LivePresenceWidget "Connect" CTAs. No empty placeholders, no dead pixels.
- **AC-2** All capture surfaces enabled + 3 OAuths connected: 6 full cards + 3 LivePresence columns clickable + Work State populated. Scroll fits 1100×720 default window without horizontal overflow.
- **AC-3** Mid-state (some on, some off): enabled cards top, disabled rows below within Surfaces section. Ordering matches `HomeSurface.allCases` within each partition.
- **AC-4** Detail screen navigation: 9 reachable detail screens, each Today/Week/Month tab re-queries within 500ms, recent events render ≤ 50 rows.
- **AC-5** Privacy walkback — grep new files for forbidden field references:
  - `grep -nE "tool_input|tool_response|command|absolute_path|note_body|email_subject|file_contents|attendee_email|debugger_state" Leaf/Views/Window/Home/ Leaf/Views/Window/SurfaceDetail/` → 0 hits.
  - `RelayBodyLeakageTests` continues to pass.
- **AC-6** Token check: `just check-tokens` — 3-tier (base / migration / retired) clean.
- **AC-7** Build matrix: `xcodebuild -workspace ... -scheme Leaf / LeafAgent / LeafMCP / LeafTests / LeafCorePrivateTests` all green.
- **AC-8** SPM tests: full suite + new Track-7 unit tests for view-model state machines + SurfaceCard / SurfaceRow snapshot tests pass.
- **AC-9** Accessibility: VoiceOver reads each surface card per §11 contract. Each compact disabled row announces "{name}, capture is off, double tap to enable".
- **AC-10** Reduce Motion ON: range tab transitions are opacity-only, no spring animations. Card spark lines render without redraw animation.
- **AC-11** Reduce Transparency ON: any glass surface (none expected on cards) falls back to solid LeafColor.surface.inset; banners use solid.
- **AC-12** Dynamic Type Largest: card text wraps to 2 lines max before truncating with ellipsis. Compact rows do not overlap.
- **AC-13** Localizable strings: all new view strings keyed via `home.surface.*`, `home.work_state.*`, `detail.*` prefixes. No hardcoded English in new view files.
- **AC-14** Performance: enabling/disabling a capture toggle triggers ≤1 SurfacesSection re-render (no whole-Home re-layout). Instruments verified — no excessive `body` evaluations.

---

## 14. Out of scope (hard exclusion)

Mirroring §1 with full enumeration:

- New event_kinds / migrations / MCP tools / schema tables.
- AI narrative ("describe my week in words") — v1.1 BYOK track.
- Phase 4.9 Derived Modes UI.
- Activity tab changes.
- Settings UI changes (toggles already shipped).
- Team / Org / Profile / MenuBar tab changes.
- Mobile (iOS) UI — Track 8+.
- Drag-and-drop card reorder (v1.1).
- Custom date-range picker on detail screens (v1.1).
- Full-text search UI over `events_fts` (separate feature).
- Cross-provider thread visualization graph (Track 7.2 candidate).
- Layer A AppleScript app aggregation cards (Music / Notes / Mail / Reminders) — Activity tab continues to surface them.
- Intensity / system observer Home aggregation cards.
- Per-row drill-down on individual Activity events.
- Light/dark theme variations beyond existing Track-2 D1 tokens.
- Profile customisation (avatar / display name beyond existing).
- New keyboard shortcuts beyond Tab/Return/Escape standard.

### 14.1 Out-of-scope but worth tracking as follow-up

- **T7.2 — Cross-provider thread graph view.** Surface `get_cross_provider_thread` MCP via dedicated drill-down (Work State decision → linked PR → linked Slack thread visualization).
- **T7.3 — Custom date-range picker.** Per detail screen, add calendar picker for arbitrary ranges. v1.1.
- **T7.4 — Drag-and-drop reorder.** v1.1 once card volume grows beyond 9.
- **T7.5 — Layer A apps aggregation.** If Music/Notes/Mail surfacing becomes glance-value-positive (depends on use patterns), reconsider for v1.1.

### 14.2 Whitepaper sync framing (public-safe)

When Track 7 ships and lands in main, whitepaper sync at `~/Desktop/Leaf/leaf-docs/`:

- New section in `docs/02-product/` describing the dashboard model: live state (LivePresenceWidget) + daily aggregates (Today) + derived insights (Work State) + per-surface drill-downs (Surfaces section).
- Update `docs/02-product/ui-philosophy.md` (or equivalent) to reflect Home-as-dashboard decision.
- Changelog entry per release version.

**Won't sync (implementation moat):** specific Derived Insights SQL bodies, view-model SQL helpers, exact aggregate thresholds, headline/sub-stat formula details. Stay in private impl modules.

---

## 15. Open questions / known gaps

| ID | Question | Status |
|----|----------|--------|
| OQ-T7-1 | Should empty Today + empty all surfaces render a higher-order onboarding nudge ("Enable a capture to start seeing data")? Or rely on inline compact-row CTAs only? | **Resolved (inline only).** Compact rows ARE the nudge. Avoid pop-over / banner stacking. |
| OQ-T7-2 | What's the right unit for Claude Code headline at low volume — `0.05M tokens` looks awkward. Switch to `52K tokens` below 1M, `M` above? | **Resolved.** Headline formatter switches K/M/B thresholds (Compact number formatter, en-US locale; localized later in P11). |
| OQ-T7-3 | Trend Δ baseline when prev period had partial data (e.g. you just started using Leaf 3 days ago and Week tab asks for 7 prev days) — render Δ anyway or omit? | **Resolved.** Omit if prev period has < 50% of expected days with any event. Threshold = 4 of 7 for Week, 1 of 1 for Today, 14 of 28 for Month. |
| OQ-T7-4 | Calendar (P6) detail screen — render an "Awaiting connection" placeholder, or skip the detail screen route entirely until GCP clears? | **Resolved.** Render placeholder via SurfaceDetailLayout with LeafEmptyState body. Route is reachable; user sees clear status. |
| OQ-T7-5 | Work State card — what if the most recent decision is 30+ days old? Show it grey, omit it, or replace with "No recent decisions"? | **Resolved.** Omit if > 30 days old. Sub-line falls back to either next-most-recent younger decision or omitted entirely. |
| OQ-T7-6 | Range tab default per surface — Week is contract-wide default, but Calendar's "events count" feels Today-relevant. Should Calendar default to Today? | **Open for P6 implementation.** Defer to phase brainstorm. Spec contract = Week default for ALL surfaces unless P6 explicitly overrides. |
| OQ-T7-7 | When a capture surface is disabled mid-session (user toggles OFF), should the full card collapse to compact row immediately, or wait for next Home re-fetch? | **Resolved.** Immediate, via @Observable state change. Animate transition with LeafMotion.spring.snappy (300ms). |
| OQ-T7-8 | Spark line baseline — render zero line explicitly (faint), or skip? | **Resolved.** Skip baseline for visual cleanliness. If all 7 days are zero, render flat low-tint line at half-height. |
| OQ-T7-9 | LivePresenceWidget chevron on hover — visible always, or hover-only? | **Resolved (hover only).** Existing widget aesthetic preserved; chevron in `LeafColor.text.tertiary` appears on hover/focus. |

---

## Appendix A — File tree (new files anticipated)

```
Leaf/Views/Window/Home/
  SurfacesSection.swift                 # NEW (P1)
  WorkStateCard.swift                   # NEW (P7)
Leaf/Views/Window/SurfaceDetail/        # NEW directory (P1)
  ClaudeCodeDetailScreen.swift          # P1
  XcodeDetailScreen.swift               # P2
  IDEsDetailScreen.swift                # P3
  BrowsersDetailScreen.swift            # P4
  ZoomDetailScreen.swift                # P5
  CalendarDetailScreen.swift            # P6
  WorkStateDetailScreen.swift           # P7
  LinearDetailScreen.swift              # P8
  GitHubDetailScreen.swift              # P9
  SlackDetailScreen.swift               # P10
Leaf/UI/Organisms/
  SurfaceCard.swift                     # P1
  SurfaceRow.swift                      # P1
Leaf/UI/Templates/
  SurfaceDetailLayout.swift             # P1
Packages/LeafCore/Sources/LeafCore/
  Home/HomeSurface.swift                # P1 (HomeSurface enum + SurfaceCatalog)
  Insights/WorkStateTypes.swift         # P7 (Decision, OpenQuestion, Blocker, WhereStoppedSnapshot, ContextRef)
  Insights/DerivedInsights+WorkState.swift  # P7 (protocol method declarations + stub extension)
  UI/<Surface>DetailMetrics.swift       # P2-P10 (public Sendable structs)
Packages/LeafCorePrivate/Sources/LeafCorePrivate/Prod/
  Insights/ProdInsights+WorkState.swift # P7 (gitignored — SQL impl)
  UI/<Surface>DetailViewModel.swift     # P2-P10 (gitignored — SQL impl)
```

## Appendix B — Token usage audit (component coverage)

| Component | Tokens used |
|-----------|-------------|
| SurfaceCard | LeafCard.raised · LeafSpace.md (12pt vertical) · LeafSpace.lg (16pt horizontal) · LeafColor.text.primary · LeafColor.text.secondary · LeafColor.accent.primary · LeafType.title.medium · LeafType.body.regular · LeafType.body.mono (numbers) · LeafIcon.lg · LeafMotion.spring.snappy |
| SurfaceRow | LeafColor.surface.raised · LeafColor.text.tertiary · LeafColor.text.primary · LeafPill (neutral) · LeafButton.secondary.sm · LeafSpace.sm · LeafIcon.md (.muted variant) |
| SurfaceDetailLayout | LeafTab · LeafCard.raised · LeafSection · LeafSpace.lg · LeafColor.text.* · LeafType.title.large (headline) · LeafType.title.medium (section titles) · LeafBanner.info (zero-data) · LeafBanner.warning (scope drift) |
| WorkStateCard | LeafCard.raised · LeafColor.text.* · LeafType.body.regular · LeafType.body.mono (counts) · LeafIcon.md (SF Symbol `bubble.left.and.exclamationmark.bubble.right`, accent.subtle tint) |
| Work State sub-row | LeafListRow base · LeafPill for context refs · LeafColor.status.warning (open blocker) · LeafColor.status.success (resolved) |

No new tokens introduced. All UI built on Track-2 D1 baseline.

---

**End of spec.** Stage 4 (writing-plans) per phase follows after user approval gate.
