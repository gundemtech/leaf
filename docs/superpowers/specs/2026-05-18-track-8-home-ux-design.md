# Track 8 — Home as Operational Console · Design Spec

**Status:** Draft (2026-05-18). Promoted to "Active" after user review gate (Stage 3) closes.
**Authors:** Dmitrii + Claude (brainstorm session 2026-05-18, visual companion).
**Stage in 8-stage workflow:** 3 (Spec write) — per-phase sessions follow approval; each phase runs `superpowers:writing-plans` → `test-driven-development` → `code-reviewer` → `verification-before-completion`.
**Predecessor:** Track 7 landed 2026-05-17 (`docs/superpowers/specs/2026-05-17-track-7-ui-surface-polish-design.md`).

---

## 1. Goal & scope

Track 7 surfaced the capture substrate as a **navigation menu** — 9 surface cards + Work State on Home; data lives one click away inside drill-downs. Author's feedback after shipping: "Home itself feels uninformative. As a dev I want to open the app and see actually adequate activity data, not buttons that hide it." Inside the drill-downs the picture is also weak (mostly placeholders + headline counts).

Track 8 rebuilds Home as an **operational console** — what's happening right now, who's working with me on this exact task, what's on my plate, where I stopped — with personal-today metrics anchored at the top. Patterns / weekly trends move out of the way (Analytics tab replaces the existing Activity tab; Activity content is killed entirely).

Fitness function:

1. **Operational frame.** Home answers two jobs: "what's happening now (me + my squad)" and "where did I stop / what needs me." Patterns / week-over-week / streaks belong on the Analytics tab, not on Home.
2. **Glanceable in 2 seconds.** Two-column grid for live row (YOU·NOW ‖ WITH YOU ON THIS), single-block INBOX with severity dots and full item titles (no opaque "PR #18"), TODAY metrics anchored at top.
3. **Squad-focused team block.** Home shows only teammates whose active context matches mine (hierarchical match: same Linear issue → same branch → adjacent branch prefix). Generic team status board moves to the existing Team tab.
4. **Read-mostly over substrate.** Re-use existing Derived Insights Engine APIs where possible. New protocol methods strictly for derivations not already in `LeafCore.Insights` — `currentTaskIdentity`, `sameTaskTeammates(rule:)`, `inboxItems(filter:query:)`, `todayMetrics`. No new event_kinds, no new migrations, no new MCP tools.
5. **Privacy invariants preserved.** Existing `RelayBodyLeakageTests` continue to pass. INBOX item titles come from already-allow-listed fields (PR title, issue title, mention excerpt). Comment preview field — explicit allow-list audit per ADR-010 walkback (see §7).
6. **Default-OFF respected.** WITH YOU ON THIS reads from `presence_history` which only exists when team relay is connected — graceful empty state when offline / pre-team / solo.
7. **Token-system fidelity.** 100% Track-2 D1 tokens. Zero hard-coded hex/pt. `just check-tokens` 3-tier clean.

**In scope:** Home redesign (5 blocks per §3 layout). Activity tab → Analytics rename + content swap (Sessions feed + Raw events views deleted; Analytics content scope only — patterns/trends UI design ships as P8 placeholder, full content design = separate spec). `WITH YOU ON THIS` matching engine (rule B hierarchical). INBOX scaffold with searchbar + filter chips for current sources (Reviews / Questions / Mentions). Per-phase acceptance smoke.

**Out of scope (hard exclusion list):**

- New event_kinds, migrations, schema columns, MCP tools, ShareEventTypeKey registry changes.
- **Peer-to-peer notes / messages / tasks** (Track 9+; requires storage table, sync semantics, delivery acknowledgment, relay extension). INBOX scaffold prepares for them but does not ship them. `Notes` / `Tasks` filter chips are **hidden** until the feature ships (soft launch, no disabled-with-tooltip ghost chips).
- **Analytics tab content design** (patterns / WoW deltas / deep-work streaks / context-switch trends / peak-hour visualizations). Track 8 ships the tab shell, rename, icon migration, and one minimal placeholder card. Detailed Analytics content = its own brainstorm + spec, runs after Track 8 lands.
- Team tab redesign. Stays as-is — full member roster, all statuses. Track 8 only changes that Home no longer competes with it.
- Connections / Organization / Settings / Profile / MenuBar UI changes.
- Onboarding changes. New users still see Home with empty states.
- AI narrative / "describe my day in words" (v1.1 BYOK track).
- Mobile (iOS) parity.
- Custom date-range picker on Home metrics (TODAY is fixed to local-day per system clock).
- Drag-and-drop block reorder.
- Per-row swipe actions on INBOX items.
- Real-time INBOX push (relies on existing 5-minute provider polling; no WebSocket for inbox).
- `INTERFERE-WITH-USER` actions on INBOX items (mark as read, snooze, archive). Click = open in source (browser / Linear / Slack). Item disappears naturally when source state changes (PR merged, question answered).

---

## 2. Decisions (locked from brainstorm)

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **Home's primary job** | Operational console (live + WIP), not analytical dashboard | Q1: C (live) + B (resumption) selected primary; A (reflection) + D (patterns) rejected |
| **Patterns / analytics location** | Separate tab — replaces existing Activity | Q2 A — keeps Home single-purpose; Activity tab content removed entirely (Sessions feed + Raw events both killed, no migration to Settings) |
| **Activity content fate** | Killed in UI. Substrate stays in DB for MCP. | Q3 user verbatim: "не нужно это показывать брат... зачем?" |
| **Home layout** | Two-column grid for live row, single-column for INBOX / Where stopped / TODAY | Q4 B — glanceable map vs vertical list; user "точно В" |
| **Team block scaling rule** | Show only teammates matching current task, full team in Team tab | Q5/Q6 — user's proposal: "показывать тех кто работает над той же задачей что и мы; остальные → раздел Team" |
| **Same-task matching rule** | Hierarchical: same Linear issue → same branch → adjacent-prefix branch | Q6 B — graceful degradation, confidence label per row ("on LEAF-204" vs "adjacent branch"); precision★★★★, recall★★★★ |
| **Empty WITH-YOU state** | Block visible with CTA "→ Team (N active elsewhere)" | Q6 bonus: option (2) — Home layout predictable, team still acknowledged |
| **INBOX block structure** | Single block, items sorted by urgency, severity dots, searchbar + filter chips | Q7/Q8 — user "инбокс оставим как есть пока что"; later "хочется поинформативнее + serchbar + фильтры" |
| **INBOX item title** | Full title of source artifact (PR title, question text, mention excerpt) not "PR #18" | Q7 #6 — "непонятно будет что такое PR 18" |
| **TODAY position** | Top of Home (above live row) | Q8 — "TODAY на самый верх... аналитика моя личная — прикольно полезно важно" |
| **TODAY metrics** | focused time / AI ratio / sessions / context switches / commits + surface-event pill strip | Q7 #6 — preserve current Today section richness; combine with new pill strip |
| **YOU·NOW states** | 4 visual variants — active (green) / in-meeting (blue) / deep-work focus (amber) / away (grey) | Q7-v2 — author approved all 4 |
| **YOU·NOW idle "Resume X?"** | Show suggestion when stale-but-recent (≤24h ago) | Q7 #3 — "да вроде ок" |
| **WHERE STOPPED on Home** | Single 2-line summary, click → opens existing Work State detail screen (Track-7 P3) | Q7 #2 — single-line is enough on Home |
| **`Notes` / `Tasks` filter chips** | Hidden until feature ships (Track 9+) | Q8 — soft launch; visible roadmap ghost-chips deemed too noisy |
| **Activity tab fate** | Renamed "Analytics" reusing same SVG icon. Content fully replaced. | User Q2 verbatim: "вместо него сделаем аналитику (с той же свг иконкой)" |
| **Analytics content scope** | Track 8 ships shell + placeholder. Full content design = separate spec. | Avoid Track-8 scope explosion |
| **Phasing** | P1 substrate + matching engine, P2 Home layout shell, P3 TODAY, P4 YOU·NOW, P5 WITH-YOU, P6 INBOX, P7 WHERE-STOPPED, P8 Activity→Analytics, P9 polish + acceptance | One session per phase per CLAUDE.md |

---

## 3. Home layout (post-Track 8)

```
┌─ Home (detail pane, NavigationStack root) ──────────────────────┐
│                                                                  │
│  TODAY · Mon 18 May                                              │  P3
│  ┌────────────────────────────────────────────────────────┐    │
│  │ 3h 24m       68%        4         12         2          │    │
│  │ focused      AI ratio   sessions  switches   commits    │    │
│  │                                                          │    │
│  │ [Claude 14] [Xcode 8] [Linear 3] [Slack 5] [+2]         │    │
│  └────────────────────────────────────────────────────────┘    │
│                                                                  │
│  ┌─ YOU · NOW ─────────────┬─ WITH YOU ON THIS · 2 ─────────┐  │  P4, P5
│  │ Xcode · HomeView.swift  │ [A] Anton  · Cursor · 12m  ✓on │  │
│  │ feature/track-8 · LEAF-…│            on LEAF-204         │  │
│  │ 42 min · ▮▮▮▯           │ [M] Maria · Figma · 4m  ~adj   │  │
│  └─────────────────────────┴────────────────────────────────┘  │
│                                                                  │
│  ┌─ INBOX · 3 ──────────────────────────────────────────────┐  │  P6
│  │ ⌕ Search inbox…                                          │  │
│  │ [All · 3] [Reviews · 2] [Questions · 1] [Mentions · 0]   │  │
│  │ ─────────────────────────────────────────────────        │  │
│  │ ● Anton commented on "Phase 5.4 — relay broadcast…"      │  │
│  │   PR #18 · gundemtech/leaf · 5m · "I think we should…"   │  │
│  │ ● Review requested: "Token sweep — retire old palette"   │  │
│  │   PR #19 · gundemtech/leaf · by Anton · 3h               │  │
│  │ ● Open question (Anton): "When do we ship 5.4 — …"       │  │
│  │   Linear LEAF-187 · 1d                                   │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌─ WHERE YOU STOPPED · 2h ago ▸ ──────────────────────────┐   │  P7
│  │ Track-7 P5 polish · WorkStateCard.swift:142             │   │
│  │ Last commit: "wf: HIG sweep accessibilityLabel parity"  │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

Removed from Track-7 Home: Surfaces section (the 9 surface drill-down cards). Detail screens themselves stay reachable (drill-downs persist), but Home no longer surfaces them as primary navigation cards. Discovery moves to: (a) TODAY pill strip — clicking a pill jumps to corresponding detail screen, (b) Analytics tab — patterns/trends content references surfaces inline. This is a Track-8 trade-off worth flagging: less discoverability for capture surfaces, more operational density on Home.

---

## 4. Block specs

### 4.1 TODAY (P3)

**Purpose:** anchor Home with personal-today snapshot. First thing eyes land on.

**Data sources (all existing in `Derived Insights Engine`):**

| Metric | Source | Notes |
|---|---|---|
| `focusedMinutes` | `focusSessions(period: today)` sum | already in `DerivedInsights` |
| `aiRatio` | `aiRatio(period: today)` | already in `DerivedInsights` |
| `sessionsCount` | count of `focusSessions(today)` | new derived (trivial) |
| `contextSwitchCount` | `contextSwitchRate(today)` × duration | already in `DerivedInsights` |
| `commitsToday` | count `git_commit` events today | already extractable |
| Surface pills | per-source event counts today | extension of existing `timeInApp` query — bucket by surface |

**States:**
- `loaded` — full metrics row + pill strip
- `loading` — skeleton placeholders (shimmer)
- `empty` — "Nothing captured yet today" centered subtitle, no pills
- `error` — banner above metrics, metrics still render last-known
- `notConfigured` — same as empty (no `LeafEmptyState` full-page; TODAY is anchor, never disappears)

**Pill click:** opens corresponding detail screen for the surface (re-uses Track-7 `pushHomeSurface` routes). `+N` overflow pill expands to show remaining pills inline (no modal).

**Layout:** single LeafCard. Metrics row uses LeafType.body for label, LeafType.title.medium for value. Pills use LeafChip token. ~140pt tall when loaded.

### 4.2 YOU · NOW (P4)

**Purpose:** show current activity state at a glance. Color-coded for state.

**Four states + state-machine transitions:**

| State | Trigger condition | Visual | Content |
|---|---|---|---|
| `active` | NSWorkspace frontmost app + idle < 5 min | Green hero `LeafColor.accent` | App · file/context · branch · LEAF-ID · duration · intensity bars |
| `inMeeting` | `meeting_state_entered` event active (Calendar S1) OR `zoom_meeting_started` active (Track-6 P5) | Blue hero `LeafColor.info` | "In a meeting" · meeting title (Cal) OR "Zoom meeting" (if no Cal link) · started · ends |
| `deepWorkFocus` | Focus mode ON via `INFocusStatusCenter` AND user actively typing (idle < 5 min) | Amber hero `LeafColor.warn` | "Deep work: {focus mode name}" · current app/file · duration |
| `away` | Screen locked OR idle > 5 min | Grey hero `LeafColor.muted` | "Locked Xm ago" OR "Idle Xm ago" · Last app + file · idle duration |

**Idle "Resume?" suggestion:** when in `away` state AND last active app is in `LocalAppsStore.enabled` AND last activity ≤ 24h ago AND last activity has Linear-ID context (via `LinearIDExtractor`) — show one-line CTA "→ Resume on LEAF-XXX in {app}". Click does not auto-launch; opens the app via `NSWorkspace.shared.open`. ≤ 24h cap avoids stale prompts after weekends.

**Priority resolution (concurrent state):** `inMeeting > deepWorkFocus > active > away`. Meeting trumps everything (you're in conversation). Focus + active resolve to `deepWorkFocus` (focus is the primary signal). Active + recent idle < 5m = `active`.

**Click behavior:** click on YOU·NOW does nothing on `active` / `deepWorkFocus` (it's your own state — no drill-down). On `inMeeting` — opens Calendar app to the meeting (if Cal-linked) or no-op (if Zoom-only). On `away` — same as Resume CTA if shown.

**Layout:** half-width LeafCard (left of 2-column grid row). ~120pt tall.

### 4.3 WITH YOU ON THIS (P5)

**Purpose:** show teammates currently active on the same task as me. Empty when solo / pre-team / offline.

**Matching engine (`sameTaskTeammates(rule: .hierarchical)`):**

For each teammate row in `presence_history` (most recent snapshot per member):

1. **`onSameLinearIssue`** (HIGH confidence) — both my active context and teammate's snapshot resolve to the same `LEAF-NN` via `LinearIDExtractor`. Source identity is current branch name → LEAF-ID extraction; falls back to `presence_state.linear.activeIssueId` if branch has no ID.
2. **`onSameBranch`** (HIGH confidence) — both active on identical branch name. Only meaningful when LinearIDExtractor returned nothing on (1) for both sides.
3. **`onAdjacentBranch`** (MEDIUM confidence) — same repo, branch names share a common prefix of ≥ 3 segments after splitting on `/` and `-` (e.g. `feature/track-8-home` ↔ `feature/track-8-analytics`). Tunable threshold; default ≥ 3 to avoid noise from `feature/x` ↔ `feature/y`.
4. **Otherwise** — not shown (falls through to Team tab).

**Confidence label rendering:**
- `onSameLinearIssue` → "on LEAF-204" badge, green
- `onSameBranch` → "same branch" badge, green
- `onAdjacentBranch` → "adjacent branch" badge, amber

**Row layout per teammate:** `[avatar] · displayName · current app · duration · [confidence-badge]`. Avatar = initial circle (consistent with existing UI). Click row → opens teammate detail in Team tab.

**Sorting:** by confidence (HIGH first), then by `lastUpdateAt` desc (most-recent activity).

**Cap:** show up to 5 rows. `+N more on this task → Team` footer if exceeded (rare for small teams; future-proofs).

**Empty state:** "No one's on this task right now." + `→ Team (N active elsewhere)` CTA. CTA shows count of teammates currently active anywhere (`presence_history` rows with `lastUpdateAt < 5 min` AND no match against rules 1-3). On 0 teammates total: "No teammates yet. Invite via Team." + CTA → Team tab.

**Offline state:** if relay WebSocket disconnected or last `presence_history` sync > 10 min ago — show muted footer "Team data stale ({lastSync} ago). Reconnecting…" Block still renders with stale rows (better than blank).

**Layout:** half-width LeafCard (right of 2-column grid row). ~120pt tall.

### 4.4 INBOX (P6)

**Purpose:** single feed of items requiring my attention.

**Item types (Track 8 ships these):**

| Type | Source | Item title | Item source meta |
|---|---|---|---|
| Review request | GitHub `pr_review_requested` where reviewer=me | PR title | `PR #N · repo · by author · {age}` |
| Comment on my work | GitHub `pr_review_comment_authored` / `issue_comment_authored` on PRs/issues I authored | "{commenter} commented on \"{PR/issue title}\"" | `PR/Issue #N · repo · {age} · "{comment excerpt up to 60 char}"` |
| @-mention | GitHub `issue_comment_authored` mentioning me / Slack `mentions_received` | "{author} mentioned you in \"{thread/issue title}\"" | `{Slack channel \| Issue #N} · {age}` |
| Open question | Linear comments matching `OpenQuestionDetector` (Track-1 D3) where target == me OR assignee == me | "Open question ({author}): \"{question excerpt}\"" | `Linear LEAF-NN · {age}` |
| Blocker affecting me | `BlockerPatternDetector` rows where `target_kind = my-issue/PR` and `resolved IS NULL` | "Blocker: \"{excerpt}\"" | `LEAF-NN \| PR #N · {age}` |

**Severity dots:**
- 🔴 danger — explicit mention of me, OR comment on my open PR/issue in last 30 min
- 🟡 warn — pending review request, open question, blocker
- ⚪ muted — viewed (clicked through) — fades to muted opacity but stays in list for the session

**Layout:**
- Header: "INBOX · N" (count = visible items after filter)
- `LeafSearchField` (search input — substring match on item title + source meta)
- `LeafFilterRow` (chips): `[All · N] [Reviews · N] [Questions · N] [Mentions · N]`
  - Counts update live as filter narrows
  - Chip `[All]` always present, selected by default
  - Hidden in Track 8: `[Notes]`, `[Tasks]` — appear when peer-messaging ships (Track 9+)
- Item list: scrollable inside block (max height 320pt; overflow scrolls within block, no full-page scroll lock)

**Item row click:** opens item in source — GitHub PR/issue in browser, Linear issue in Linear app (or browser if app missing), Slack thread in Slack app. Click does NOT mark anything as read (out of scope per §1).

**Aggregation rule:** items appear at most once. If Anton comments 5 times on PR #18 in last hour, INBOX shows ONE row "Anton commented on PR #18 (5)" with count badge. Click opens PR conversation tab.

**Empty state:** "All clear. No reviews, questions, or mentions." Filter chips still visible with `· 0` counts. No CTA — empty inbox is good.

**Refresh:** items derived on-demand from existing event tables (re-uses Layer B 5-min polling). No new poll loop. Block re-derives on `InsightsReader.refresh()` (existing pull-to-refresh / focus-change trigger).

**Layout:** full-width LeafCard. ~280pt tall when populated (3 items default visible, scroll for more).

### 4.5 WHERE YOU STOPPED (P7)

**Purpose:** glance-summary of last work context. Click → existing Work State detail (Track-7 P3 — `WorkStateDetailScreen`).

**Data sources (existing):**
- `WhereStoppedDeriver` snapshot (Track-1 D3) — most recent row from `where_stopped_log`
- Last commit in any tracked git repo — via existing collector

**Display:**
- Header: "WHERE YOU STOPPED · {age}" where age = time since `where_stopped_log.generated_at_ms`
- Line 1: snapshot excerpt + file ref (e.g., "Track-7 P5 polish · WorkStateCard.swift:142")
- Line 2: last commit subject (60 char cap) if commit ≤ 4h ago, otherwise omitted

**Click:** routes to `WorkStateDetailScreen` (already implemented in Track-7 P3) via `RouteCoordinator.pushHomeWorkState()`.

**Empty state:** "No recent stop-points captured." Block still renders (consistent layout).

**Layout:** full-width LeafCard, compact. ~80pt tall.

### 4.6 Removed: Surfaces section

The 9 surface drill-down cards from Track-7 are **removed from Home**. The detail screens themselves stay reachable, but Home no longer surfaces them as primary navigation.

**Replacements for discovery:**
- TODAY pill strip — `[Claude 14]` chips link to corresponding detail screens
- Analytics tab — links to surface detail screens from inline pattern callouts (e.g., "Top tools this week: Bash, Read, Edit" with surface chips)
- `WindowSettings → Connections` already lists every surface with enable/connect controls

Trade-off explicitly accepted: less discoverability for newly-enabled capture surfaces, more operational density on Home. Author judged operational > discoverability for the current dev-focused user.

---

## 5. Activity → Analytics (P8)

**Rename:** `WindowSection.activity` → `WindowSection.analytics`. SVG icon reused (`LeafIcons.nav.activity` → renamed file `analytics` OR keep file name and rename only the enum case; choose during P8 implementation based on which is less churny).

**Content swap:**
- `ActivityView.swift` — entire body replaced.
- `SessionRow.swift`, `ActivityRow.swift` — deleted (Sessions feed mode + Raw events filter — both killed per Q3 decision).
- New `AnalyticsView.swift` — Track-8 ships **minimal placeholder**:
  - Header "Analytics"
  - Single LeafSection with `LeafEmptyState`: "Analytics view coming soon. Patterns, trends, and weekly summaries will land here."
  - Week-scoped surface chip strip (mirrors TODAY pills, scaled to week) — drives discovery while the real content cooks.

**Content design DEFERRED:** Full Analytics surface design (week breakdown chart, deep-work streaks, peak-hour, top tools, WoW deltas, AI ratio over time, etc.) = separate brainstorm + spec ("Track 8.5" or "Track 9", to be decided after Track 8 lands).

**Why ship the rename now (not later):** Activity tab actively misleads users — current content is "просто какие-то данные" with no insight, hurting perceived product polish. Replacing with empty Analytics shell is **less bad** than current state (honest "coming soon" beats noisy data exhibit).

---

## 6. Substrate inventory

### 6.1 Existing — reuse as-is

| Subsystem | What we use |
|---|---|
| `DerivedInsights` protocol | `timeInApp`, `focusSessions`, `contextSwitchRate`, `aiRatio`, `peakProductivityHour`, `weekOverWeekDelta`, `filesTouched` |
| Track-1 D3 detection tables | `decisions`, `open_questions`, `blockers`, `where_stopped_log` (driven by `DetectorPipeline`) |
| `LinearIDExtractor` (Phase 4.7.A) | Branch / PR title / commit message → LEAF-NN |
| `presence_state` table | Self snapshot (linear, github, slack composites) |
| `presence_history` table | Teammates' most recent snapshots (forever-retention; Track 4.7.B + 5.x) |
| `event_links` | GitHub PR ↔ Linear issue ↔ Slack thread cross-refs |
| `LocalAppsStore` | Per-app enable toggles (idle Resume eligibility) |
| `InsightsReader` (`@Observable`) | Main UI data source; existing pull-to-refresh + focus-change |
| `RouteCoordinator` (Track-7) | `pushHomeSurface`, `pushHomeWorkState`, `pushHomeLayerB` already wired |
| `LeafSearchField`, `LeafFilterRow`, `LeafChip`, `LeafCard`, `LeafSection`, `LeafEmptyState` | All in Track-2 D1 tokens. No new components. |

### 6.2 New — Track 8 derives

| API | Returns | Lives in | Notes |
|---|---|---|---|
| `DerivedInsights.currentTaskIdentity()` | `TaskIdentity { linearID?, branch?, repo?, workspacePath? }` | LeafCorePrivate (Prod impl), LeafCore (protocol) | Inspects most-recent self events to compute identity. Pure function over current `presence_state.self`. |
| `DerivedInsights.sameTaskTeammates(rule:)` | `[TeammateMatch { member, confidence, contextLabel }]` | LeafCorePrivate (Prod), LeafCore (protocol) | Joins `presence_history` rows against `currentTaskIdentity()`. `rule = .hierarchical` ships. |
| `DerivedInsights.inboxItems(filter:query:)` | `[InboxItem { kind, severity, title, sourceMeta, sourceURL, createdAtMs }]` | LeafCorePrivate (Prod), LeafCore (protocol) | Unifies Layer B feeds + D3 detection. `filter = .all / .reviews / .questions / .mentions`. `query: String?` substring match. |
| `DerivedInsights.todayMetrics()` | `TodayMetrics { focusedMin, aiRatio, sessionsCount, switchCount, commitsCount, surfacePills: [(name, count)] }` | LeafCorePrivate (Prod), LeafCore (protocol) | Bundles the 5 anchor metrics + pill strip into single fetch (avoids 6 round-trips on Home load). |
| `YouNowState` enum + deriver | `.active / .inMeeting(title?, ends?) / .deepWorkFocus(modeName, app?) / .away(reason, lastApp?, idleDuration)` | LeafCore | Pure function over `presence_state.self` + Calendar/Focus collectors. |

**No new SQLCipher tables.** No new migrations. No new ShareEventTypeKey entries.

### 6.3 New SwiftUI views

| View | Replaces / new | Lives in |
|---|---|---|
| `TodayBlock.swift` | new (replaces inline `TodaySection` in `HomeView.swift`) | `Leaf/Views/Window/Home/Blocks/` |
| `YouNowBlock.swift` | new (replaces existing Hero region) | same |
| `WithYouOnThisBlock.swift` | new (replaces `LivePresenceWidget` on Home; LivePresenceWidget itself either kept for Team tab use or deleted if no longer referenced) | same |
| `InboxBlock.swift` + `InboxItemRow.swift` + `InboxFilterRow.swift` | new | same |
| `WhereStoppedBlock.swift` | new — compact summary; opens existing `WorkStateDetailScreen` on click | same |
| `AnalyticsView.swift` | new (replaces `ActivityView.swift`) | `Leaf/Views/Window/Analytics/` |
| Deleted | `ActivityView.swift`, `ActivityRow.swift`, `SessionRow.swift`, `RecentSessionsBlock.swift`, `SurfacesSection.swift` | — |

`HomeView.swift` itself shrinks substantially — from current 675 lines to ~150-200 lines (block composition only; logic moves to per-block views).

---

## 7. Privacy walkback audit

The one new field surfaced on UI is **PR/issue comment excerpt** in INBOX rows (e.g. "I think we should split the encode path"). Per ADR-010 Won't-list:
- Comment **body** capture is already permitted (existing `pr_review_comment_authored` event kinds include the body in event payload as `body_excerpt` with 60-char cap at the parser boundary, per Track-3 D2 design).
- Surfacing the existing `body_excerpt` field on UI does **not** expand the privacy surface. No new field added.
- `RelayBodyLeakageTests` adds one sentinel-injection test (P6 task): inject `LEAKED_SENTINEL_INBOX_BODY` into the `body_excerpt` field of a synthetic event and assert it does NOT appear in `presence_outgoing` (broadcast surface). Inbox is local-render only; never leaves device.

**Other new UI elements — no new privacy surface:**
- Confidence labels ("on LEAF-204", "adjacent branch") — derived from branch names, which are already shipped in payload.
- YOU·NOW meeting title — uses `EventKit` meeting state event which is already on the captured-permitted list (event_kind `meeting_state_entered` already has the title in payload per Phase 4.10 + Track-4 S1).
- Same-task teammate context label (app + duration) — already in `presence_history` shipped by relay.

**Verification:** P9 acceptance gate runs `grep -nE "absolute_path|full_comment_body|raw_email|notes_body" Leaf/Views/Window/Home/` to confirm no leakage paths in new files. Expected: 0 hits.

---

## 8. State machines

### 8.1 Home top-level (drives header layout choice)

States borrowed from existing `InsightsReader.State`:
- `.loading` → all blocks render skeleton placeholders. No CTA.
- `.notConfigured` → full-page `LeafEmptyState` "Connect a provider to see your data" + `Open Connections` CTA. (Same as current.)
- `.empty` → blocks render with their individual `empty` states. Home anchor (TODAY) still visible with "Nothing captured yet."
- `.error(msg)` → `LeafBanner.danger` at top, blocks render last-known data. (Same as current.)
- `.loaded(snapshot)` → full 5-block render per §3.

### 8.2 Per-block state (each block has its own derived state from snapshot)

Each block has `loading / loaded / empty / error` independent — top-level `.loaded` doesn't force every block to be `loaded`. Example: TODAY loaded with data, WITH YOU empty (no match), INBOX loaded with 0 items but filters visible.

### 8.3 YOU·NOW state machine

Documented in §4.2. Single-state-at-a-time with priority resolution.

---

## 9. Phasing

Per CLAUDE.md "one phase = one session". 9 phases.

| Phase | Scope | Substrate work | UI work |
|---|---|---|---|
| **P1 — Substrate + matching engine** | New `DerivedInsights` APIs + `YouNowState` deriver + `sameTaskTeammates` engine | Protocol additions + LeafCorePrivate impls + tests | None |
| **P2 — Home layout shell** | Replace `HomeView.swift` with new 5-block composition. Stub blocks with placeholders. Delete `SurfacesSection.swift` from Home. | None (UI shell only) | `HomeView.swift` rewrite, block files created with placeholder bodies |
| **P3 — TODAY block** | Wire `todayMetrics()` into `TodayBlock.swift`. Metrics row + pill strip. Click-through routing for pills. | `todayMetrics()` impl light-up | `TodayBlock.swift` |
| **P4 — YOU·NOW block** | 4 states + transitions + idle Resume CTA | `YouNowState` deriver impl | `YouNowBlock.swift` |
| **P5 — WITH YOU ON THIS** | Matching engine wired to UI, confidence badges, empty state with Team CTA, offline footer | `sameTaskTeammates(.hierarchical)` impl + tests | `WithYouOnThisBlock.swift` |
| **P6 — INBOX block** | Items derive from Layer B + D3, severity logic, filter chips, searchbar, aggregation dedup | `inboxItems(filter:query:)` impl + sentinel-leakage test | `InboxBlock.swift`, `InboxItemRow.swift`, `InboxFilterRow.swift` |
| **P7 — WHERE YOU STOPPED** | Compact summary + click → existing detail | None new (reuse Track-1 D3 + existing route) | `WhereStoppedBlock.swift` |
| **P8 — Activity → Analytics** | Tab rename in `WindowState.WindowSection` + icon. Delete `ActivityView.swift` + `ActivityRow.swift` + `SessionRow.swift` + `RecentSessionsBlock.swift`. Ship `AnalyticsView.swift` placeholder. | None | `AnalyticsView.swift`, `WindowState.swift` enum rename |
| **P9 — Polish + acceptance** | HIG sweep, accessibility labels, token-fidelity sweep, performance pass (Home load < 16ms paint), manual smoke per §10, **+ carry-over backlog §9.1** | Per-carry-over (see §9.1) | Per-block polish, accessibility props |

Each phase ships behind a feature branch, gets independent code-review subagent run + verification-before-completion. Collective merge of P1-P9 happens after P9 acceptance gate clears.

### 9.1 P9 carry-over backlog

Items deferred from earlier phases. Append to this list during phase wrap so nothing falls through. P9 closes all entries or explicitly re-defers to v1.1.

**From P3 (TODAY block):**

- **C-1 Hybrid surface pills** — replace current `SurfacePill.label`-only render with semantic per-surface units: capture-surfaces (Claude Code / Xcode / IDEs / Browsers / Zoom / Calendar) show attention-time (e.g. `Claude Code · 1h 47m`); Layer B providers (Linear / GitHub / Slack) show action-noun count (e.g. `Linear · 3 issues`, `GitHub · 5 commits`, `Slack · 12 msgs`). Requires substrate change: extend `SurfacePill` shape (decision: `displayValue: String` precomputed by substrate vs `kind` enum dispatched by view — brainstorm at P9), add 3 SQL queries in `ProdInsights+TodayMetrics.swift` (Linear distinct issues / GitHub commits / Slack messages today), and close **Phase 8.1 emission gap** — current substrate only emits capture-surface pills, never Layer B (router `LayerBProvider` branch is dead code today).
- **C-2 Error-state last-known retention** — Phase 8.3 spec §6 + MS-5 assumed `InsightsReader.State.error` carries last-known snapshot so TODAY card renders with prior metrics under a danger banner. Current `InsightsReader.State.error(message: String)` has no snapshot field — state machine refactor needed (`error(message: String, lastKnown: InsightsSnapshot?)`) + `HomeView` rendering tweak so `.error` shows banner above `HomeContent(snapshot: lastKnown)` instead of full-page banner.
- **C-3 Narrow-window wrap fallback** — TODAY metrics row is a fixed `HStack`; expected visible clip if popover width < ~520pt. Spec §10 R-4 deferred — add `ViewThatFits` 2-row compact fallback.
- **C-4 DateFormatter caching** — `TodayBlock.sectionLabel` allocates a `DateFormatter` per render. Tiny cost in practice but trivial fix: `static let` cached formatter (note: `setLocalizedDateFormatFromTemplate` is locale-aware, so cache by locale or accept en_US-only).
- **C-5 YouNowBlock LocalAppsStore reactivity gap (P4 carry)** — `YouNowBlock` constructs `LocalAppsStore()` as `@StateObject` (per-view instance). UserDefaults reads are consistent across instances, but `objectWillChange` fires only on the Settings instance when user toggles a bundle enabled flag. Home's Resume CTA won't reactively hide/show until the next `InsightsReader.refresh()` tick. Bounded by refresh cadence; fix = inject a single shared `LocalAppsStore` from app root via `.environmentObject(...)` and consume via `@EnvironmentObject`.
- **C-6 YOU·NOW inMeeting tap → Calendar `ical://` deep-link (P4 carry)** — master §3.4 says inMeeting click "opens Calendar app to the meeting (if Cal-linked)". P4 ships as no-op (tap gate confined to `.away` for Resume CTA). Calendar deep-link needs `ical://` URL scheme research (start time + UID lookup) + tap modifier extension to also gate on `.inMeeting`. Pairs naturally with substrate gap C-9 so the meeting render carries enough info to build a deep-link.
- **C-7 YouNowBlock accessibility — Button wrap on .away (P4 carry)** — tap target is `.contentShape(Rectangle()).onTapGesture` (gated to `.away`), not a wrapping `Button`. VoiceOver may not announce the tappable affordance. Add explicit `Button` wrapper around the `.away` row or apply `.accessibilityAddTraits(.isButton)` on the card when CTA-eligible. Pairs with P9 accessibility audit pass.
- **C-8 Resume CTA branch-deletion staleness (P4 carry)** — if `lastLinearID` was extracted from a now-deleted branch, Resume CTA still renders with stale ID. v1.1 — validate via `LinearIDExtractor` registry refresh or `git branch --list` check before showing CTA. Not blocking ship.
- **C-9 YouNowMeeting substrate enrichment (P4 carry, cross-track)** — `ProdInsights+YouNowState.swift` hard-codes `meetingTitle: nil`, `meetingEndsAtMs: nil`, and `meetingSource` only `.eventKit` (Zoom never fires). Substrate enrichment needed: read meeting title from `meeting_state_entered` event payload (per ADR-010 allow-list), fetch `endsAtMs` from same payload, merge `zoom_meeting_started` snapshots into source `.both` when overlap window matches. Separate substrate track — not pure P4.

**From P5 (WITH YOU ON THIS):**

- **C-10 WithYouOnThisBlock empty-state CTA missing N count.** Spec §4.3 calls for "→ Team (N active elsewhere)" where N = teammates active anywhere who don't match my task. P5 ships CTA as "→ Team" without count. Resolution requires either (a) new `totalActiveTeammates` deriver, or (b) plumbing teammate list through `InsightsSnapshot` (privacy surface expansion — list of all teammates, not just matches). Phase 5.4 enrichment. File: `Leaf/Views/Window/Home/Blocks/WithYouOnThisBlock.swift:emptyState`.
- **C-11 WithYouOnThisBlock offline / stale footer absent.** Spec §4.3 calls for muted footer "Team data stale ({lastSync} ago). Reconnecting…" when relay disconnected OR last `presence_history` sync > 10 min. No relay status signal in `InsightsSnapshot` today. P9 / Phase 5.6 carry — pairs with relay status plumbing.
- **C-12 Row tap routes to Team tab without teammate selection.** Spec §4.3 "Click row → opens teammate detail in Team tab" — Team tab has no per-teammate detail screen. P5 ships row tap as `windowState.section = .team`. Resolution = Team-tab teammate detail screen + `RouteCoordinator.pushTeam(memberID:)`. Track-9 / separate feature.
- **C-13 TeammateMatch.durationSec hardcoded 0 in substrate.** `SameTaskMatcher.makeMatch` sets `durationSec: 0` unconditionally (`Packages/LeafCore/Sources/LeafCore/Insights/SameTaskMatcher.swift:73`). UI does not surface a "duration on task" field today (row line 2 uses `lastActivityAtMs` "ago" relative time). Substrate enrichment (compute duration from earliest task-matching snapshot per teammate) is Phase 5.4 / Track-9 territory.

**Open for append:** P4 / P5 / P6 / P7 / P8 add their own carry-overs to this list at phase wrap. Each entry: ID, one-line summary, file/spec ref, rationale for defer.

---

## 10. Acceptance criteria (P9 manual smoke)

| AC | Description | Expected |
|---|---|---|
| AC-1 | Open Leaf with active session in Xcode editing a file — TODAY anchor + YOU·NOW green + 1 row in WITH YOU (if Anton on same task) + INBOX populated | Home renders in < 500ms cold, < 100ms warm |
| AC-2 | Switch app to Zoom + start meeting (Cal-linked) — YOU·NOW transitions to blue inMeeting within ≤ 30s | Title + ends-in shown |
| AC-3 | Enable Focus mode "Deep work" — YOU·NOW transitions to amber deepWorkFocus | Mode name + current app shown |
| AC-4 | Lock screen for > 5 min — YOU·NOW transitions to grey away with "Resume on LEAF-XXX in Xcode" CTA (if last activity has LEAF-ID) | CTA opens Xcode via NSWorkspace |
| AC-5 | Branch to `feature/track-8-foo`, branch Anton to `feature/track-8-bar` — WITH YOU ON THIS shows Anton with "adjacent branch" amber badge | Within ≤ 5 min after Anton's next polled snapshot |
| AC-6 | Anton checks out `feature/track-8-home` (my branch) — Anton's row badge promotes to "same branch" green | After polled snapshot |
| AC-7 | Solo state — branch with no LEAF-ID, no teammates anywhere — WITH YOU shows empty CTA "→ Team (0 active elsewhere)" | Block visible, no broken layout |
| AC-8 | INBOX with Anton comment on my PR — row appears with red severity dot, comment excerpt visible, click opens PR in browser | Excerpt ≤ 60 char with ellipsis |
| AC-9 | INBOX filter "Reviews" — list narrows to PR-review items only, counts update | Chip counts: All=N total, Reviews=N filtered |
| AC-10 | INBOX search "track-8" — items with "track-8" in title or source meta visible, others hidden | Substring case-insensitive |
| AC-11 | INBOX empty — "All clear. No reviews, questions, or mentions." centered, filter chips still visible with `· 0` | No CTA |
| AC-12 | WHERE YOU STOPPED single-line — click opens existing `WorkStateDetailScreen` | Existing detail loads |
| AC-13 | Activity tab is gone, Analytics tab visible with same SVG icon, opens placeholder view | Sidebar enum renamed correctly |
| AC-14 | Privacy walkback grep — `grep -nE "absolute_path\|full_comment_body\|raw_email\|notes_body" Leaf/Views/Window/Home/` returns 0 hits | Same for `Leaf/Views/Window/Analytics/` |
| AC-15 | Token sweep — `just check-tokens` passes 3-tier (BASE + MIGRATION + RETIRED) | 0 violations |
| AC-16 | All 5 xcodebuild schemes Debug build SUCCESS (LeafCore / LeafCorePrivate / Leaf / LeafAgent / LeafMCP) | 5/5 green |
| AC-17 | SPM test suite — `swift test` 0 failures across LeafCore + LeafCorePrivate | New tests: matching engine + inbox derivation + YouNowState transitions |
| AC-18 | Performance — Home initial paint < 16ms (60fps budget), measured via SwiftUI Instruments Time Profiler with a populated DB | No Long-Lived Body Recalculation warnings |

---

## 11. Risks & open questions

| ID | Concern | Mitigation / decision needed |
|---|---|---|
| R-1 | `currentTaskIdentity()` accuracy degrades when working in multiple projects in parallel (Xcode + browser + Linear all active different contexts) | Use frontmost-app + active-file as primary signal. Linear-ID derives only from branch of repo containing frontmost file. Document edge case; degrades to `nil` identity → WITH YOU shows empty. |
| R-2 | `sameTaskTeammates` matching may show false positives when team has many parallel `feature/track-8-*` branches (adjacent rule too loose) | Default adjacent threshold ≥ 3 shared segments. Constant in `LeafCore` (not user-configurable in Track 8). v1.1 may expose a setting if false-positive complaints emerge. P5 manual smoke verifies on real branch shape. |
| R-3 | INBOX aggregation dedup may collapse important distinct comments | Keep most recent excerpt + count badge. Verify in P6 manual smoke with 5+ rapid comments on one PR. |
| R-4 | "Comment on my work" (GitHub) requires knowing which PRs/issues I authored — adds light join on existing event tables | P1 derivation queries `gh_pr_opened` events where `author_login == viewerLogin` to build my-authored set in-process. No new persistence. |
| R-5 | Activity tab deletion may break existing acceptance tests / snapshots if any reference the old IA | P8 task: grep-search for `WindowSection.activity` / `ActivityView` references in tests, update. Document in P8 spec. |
| R-6 | YOU·NOW `deepWorkFocus` requires Focus mode TCC permission (INFocusStatusCenter) — may be denied | Graceful degrade: if no permission → state never enters `deepWorkFocus`, stays `active`. Settings deep-link banner in onboarding if user wants the variant. Existing Phase 4.10 handles permission. |
| OQ-T8-1 | Should YOU·NOW idle-Resume CTA also fire when teammate is on the same task (e.g., "Anton's on LEAF-204 — resume to join him")? | Defer to post-Track-8. Track 8 fires Resume only off own state, not team-derived. |
| OQ-T8-2 | TODAY pills: clicking `Linear 3` opens Linear surface detail screen (still exists post-Track-8) — OR opens Analytics tab on Linear week view? | Ship as detail-screen link in P3. Re-evaluate when Analytics content lands. |
| OQ-T8-3 | When TODAY metrics arrive late (5s after Home open) — flash of empty → loaded acceptable? Or skeleton always until loaded? | P3 decision: ship skeleton-always for ≥ 250ms, then real value. No flash. |
| OQ-T8-4 | Maximum INBOX item age — do we show items older than 7 days? | P6 default: 14-day cap. Items older than 14 days don't appear (PR review requests over 2 weeks old are stale signal). Tunable. |

---

## 12. Files touched

**New:**
- `docs/superpowers/specs/2026-05-18-track-8-home-ux-design.md` (this file)
- `Leaf/Views/Window/Home/Blocks/{TodayBlock,YouNowBlock,WithYouOnThisBlock,InboxBlock,InboxItemRow,InboxFilterRow,WhereStoppedBlock}.swift`
- `Leaf/Views/Window/Analytics/AnalyticsView.swift`
- `Packages/LeafCore/Sources/LeafCore/Insights/YouNowState.swift`
- `Packages/LeafCore/Sources/LeafCore/Insights/TaskIdentity.swift`
- `Packages/LeafCore/Sources/LeafCore/Insights/TeammateMatch.swift`
- `Packages/LeafCore/Sources/LeafCore/Insights/InboxItem.swift`
- `Packages/LeafCore/Sources/LeafCore/Insights/TodayMetrics.swift`
- `Packages/LeafCore/Sources/LeafCorePrivate/...` — Prod impls (gitignored module)
- Tests for each new derivation + matching engine + YouNowState transitions

**Modified:**
- `Leaf/Views/Window/Home/HomeView.swift` (rewrite, ~150 LOC down from 675)
- `Leaf/Models/WindowState.swift` (enum case rename)
- `Packages/LeafCore/Sources/LeafCore/Insights/DerivedInsights.swift` (protocol additions)
- `Leaf/Routing/RouteCoordinator.swift` — add `pushHomeAnalytics()` route + `AppRoute.analytics` case to drive sidebar selection from in-Home links (TODAY pills, future Analytics-tab back-references). Decided up-front to avoid scope-creep in P8.
- `.claude/shared/current-state.md` (final P9 commit)

**Deleted:**
- `Leaf/Views/Window/Activity/ActivityView.swift`
- `Leaf/Views/Window/Activity/ActivityRow.swift`
- `Leaf/Views/Window/Activity/SessionRow.swift`
- `Leaf/Views/Window/Home/SurfacesSection.swift`
- `Leaf/Views/Window/Home/RecentSessionsBlock.swift`
- `Leaf/Views/Window/Home/LivePresenceWidget.swift` — verify Team-tab usage in P2 grep sweep. If no Team-tab reference, delete in P5 (WITH YOU ON THIS supersedes it on Home). If Team tab consumes it, move file to `Leaf/Views/Window/Team/` and keep.

---

## 13. References

- Brainstorm session: `.superpowers/brainstorm/43966-1779054033/` (gitignored; visual mockups Q1-Q8)
- Predecessor: `docs/superpowers/specs/2026-05-17-track-7-ui-surface-polish-design.md`
- Substrate baselines:
  - `.claude/shared/architecture.md` (Derived Insights Engine, Track-1 D3 tables, Layer B)
  - `.claude/shared/current-state.md` (Track-7 ship state, deferred items per §10 D-3)
- Privacy contract: ADR-010 (Won't-list), referenced via whitepaper `~/Desktop/Leaf/leaf-docs/docs/privacy-security/won-t-list.md`
