# Track 5 / S7 — Alternatives Analysis

> Companion to forthcoming `2026-05-16-track-5-S7-team-ui.md`. Audit trail for design calls. 22 areas brainstormed; recommendations folded back into main spec. Pattern mirrors S6 alternatives audit (`2026-05-16-track-5-S6-cross-post-alternatives.md` — 17 areas, drove 9 material spec changes).

Format per area: **Question** → **Options A/B/C/...** → **Trade-offs** → **Recommendation + reasoning** → **Effect on spec**.

Sections:
- **B-series** (B1-B5) — architecture / boundary questions emerging from Discovery substrate map.
- **OQ-series** (OQ-S7-1..17) — UX questions enumerated in `track-5-S7-session-start.md`.

## Amendment 2026-05-16 (review iteration)

After initial brainstorm, user redirected on 2 OQs and gave «unlimited budget — pick most optimal+convenient» mandate for remaining redirect points. Net changes from initial draft:

| Area | Initial | Revised | Reason |
|---|---|---|---|
| OQ-1 | B per-platform name | **C full target name + clickable URL** | Sender already disclosed channel by cross-posting; max convenience for recipient navigation |
| OQ-5 | D popover 9 toggles | **D popover 10 toggles (+«Open Tasks only»)** | Adds highest-utility «things I owe action» filter |
| OQ-6 | A toolbar | A toolbar + **⌘N keyboard shortcut** | Quick-send for power users |
| OQ-10 | B+C 300ms auto-read | **B+C 1500ms auto-read + keyboard nav** | 300ms = scroll-past false-positive; 1500ms = read confidence; arrow/space/⌘R keys |
| OQ-12 | 5+/10m grouping | **5+/15m + timeline span in collapsed row** | 15m catches longer work-sessions; «5m ago — 18m ago» span gives burst context |
| OQ-14 | symmetric badge | symmetric badge + **outbound read-receipt** | Free with Realtime — recipient mark-read → Realtime push → sender card shows «Read 2m ago» |
| OQ-15 | 4pt accent stripe | **leading checkmark icon + emphasis text** | Stripe conflicts with macOS sidebar main-nav selection; checkmark pattern matches Mail account picker |
| OQ-16 | 30s + scenePhase eager | **Supabase Realtime WS + 30s fallback** | User mandate: «realtime надо» |
| OQ-17 | deferred S8/Track 6 | **rich `LeafLinkedEventCard` in S7** | Auto-upgraded per «unlimited budget» — cached metadata + fetch-on-miss |
| B5 | minimum Settings | **full Settings → Workspace surface** | User mandate: «никаких минимумов» — name edit + members admin (kick) + invites admin + leave + delete + new-workspace |

**Plus auto-added carry-over upgrades:** M5 cross-post failure retry (Realtime-driven banner in Send sheet) folded into S7 scope as side-effect of Realtime substrate.

**New components total: 13** (was 6 — added `LeafLinkedEventCard`, 5 Workspace Settings sub-views + relocated `PendingInvitesAdminSection`, `DeleteWorkspaceConfirmationModal`, `WorkspaceCreateSheet`).
**New readers/services total: 4** (was 2 — added `AttachmentMetadataResolver`, `LeafRealtimeService`).
**`WorkspaceService` extensions: renameWorkspace + deleteWorkspace.**

Remaining sections below describe the initial brainstorm reasoning; refer to this Amendment for final decisions where they differ.

---

## B1 — Where does the unified Team feed live in the nav?

**Q:** Current sidebar has `.team` + `.organization` items. S7 removes `.organization`. Where does the new unified feed render?

- **A** Replace `.team` destination — `TeamView` becomes the unified feed (current adaptive-grid members UI subsumed by pill-row members + feed below).
- **B** Keep `.team` as members grid (today's TeamView), add new `.feed` nav item.
- **C** Rename `.team` → `.activity-team`; absorb both members + feed in same view (same as A but rename for clarity).

**Trade-offs:**
- B doubles nav surface without semantic gain — members + their activity are conceptually one thing.
- C surface rename = test breakage + user confusion mid-track.
- A matches Track 5 contract §4 ("unified feed + filter chips + pill-row members + sticky Send + 3 empty states") — Team tab IS the feed.

**Recommendation: A.** TeamView refactored to host the unified feed. Existing adaptive-grid members layout becomes pill-row at top (compact, scrollable per OQ-9 overflow strategy). Empty + loaded + error states preserved. Sidebar `.organization` item deleted entirely. `OrganizationView.swift` deleted (per session-start.md "hard-delete after Team feed subsumes its surface").

**Spec effect:** §3 architecture states "TeamView refactor in place (not new file)". §6 lists 4 nav items post-S7 (Home / Activity / Team / Connections + Settings + Profile). §7 OrganizationView.swift removal in cleanup commit.

---

## B2 — Where do the 4 new atoms live in `Leaf/Theme/`?

**Q:** `LeafMessageCard` / `LeafFeedRow` / `LeafWorkspaceSwitcher` / `LeafFilterChips` — Composites/, Layouts/, or Primitives/?

Existing structure (from Discovery):
- `Primitives/` — divider, dot, icon, icon-chip, spacer (atomic visual fragments).
- `Composites/` — avatar, badge, button, icon-button, input, pill, progress, select, sparkline, status-pill, tab, toggle, metric-* (small reusable widgets).
- `Layouts/` — banner, card, empty-state, list-row, menu-bar-layout, nav-row, onboarding-step-layout, section, sheet-layout, toolbar, window-layout (multi-element scaffolds).

Categorization per new atom:

- `LeafMessageCard` — composes avatar + icon + LeafCard.raised + text + inline actions. **Layouts/** (multi-element scaffold like LeafListRow / LeafCard).
- `LeafFeedRow` — composes icon + text + timestamp + optional action. **Layouts/** (mirror of LeafListRow / LeafNavRow but tighter, feed-specific).
- `LeafWorkspaceSwitcher` — composes avatar + label + chevron + dropdown menu. **Composites/** (single-purpose widget with internal state).
- `LeafFilterChips` — composes N LeafPill instances in HStack with selection state. **Composites/** (single-purpose widget; LeafPill is the primitive).

**Recommendation: as above** — 2 in Layouts/, 2 in Composites/. Matches existing pattern (LeafCard / LeafListRow in Layouts/; LeafBadge / LeafToggle in Composites/). Also: each atom has matching `*Tokens.swift` in `Theme/Tokens/Components/` (spacing/typography pinned per token tier).

**Spec effect:** §7 file-layout enumerates 4 new files in Layouts/ + Composites/ + 4 corresponding token files in Tokens/Components/. Preview files in `Leaf/Views/Tokens/Components/` to mirror existing TokensPreview pattern (`⌘⌥T` discoverability).

---

## B3 — Send sheet trigger — keep S6 closure injection or hoist?

**Q:** S6 `SendDirectMessageSheet` accepts closures `onReauthorizeSlack` + `resolveLinearAssignee` from call site (OrganizationView injects them). S7 changes the call site to TeamView. Pattern choice:

- **A** Preserve closure-injection contract verbatim — TeamView passes the same two closures from its `.environment(SlackOAuthService)` + `linearUsersResolver`.
- **B** Hoist resolution into the sheet itself — sheet reads `SlackOAuthService` + resolver via `@Environment` directly.
- **C** Add explicit `SendDirectMessageSheetHost` view wrapping the closure-wiring.

**Trade-offs:**
- A: zero changes to S6 sheet code; pure relocation of call site. SwiftUI-pure invariant preserved (sheet stays test-isolated from OAuth + actor types).
- B: cleaner call site but couples sheet to OAuth/actor types → harder to preview/test in isolation; reason S6 went closure-injection in first place.
- C: redundant wrapper for ~5 LOC win.

**Recommendation: A (no change).** Closure-injection is a deliberate S6 architectural choice; S7 relocates call site, not the contract. Comment in TeamView call site cross-references S6 spec §9 (UI patterns).

**Spec effect:** §9 implementation steps explicitly preserve S6 sheet API; refactor scope = "move sheet invocation from OrganizationView → TeamView, identical closure args".

---

## B4 — `WorkspaceReader.leaveActiveWorkspace()` — public LeafCore or LeafCorePrivate moat?

**Q:** NIT-3 carry-over from S2: `WorkspaceReader.leaveActiveWorkspace()` not implemented. S7 right-click menu "Leave" requires it. Where does the impl land?

- **A** Public LeafCore — soft-mark logic is pure SQL (UPDATE `workspaces SET left_at_ms = ? WHERE id = ?`); no Supabase moat involvement; readable in OSS.
- **B** LeafCorePrivate — symmetric with other Workspace ops if any leak server-side details.

Investigation: existing `WorkspaceService.markLeft(workspaceID:)` already lives in public LeafCore (S2 spec). `WorkspaceReader.leaveActiveWorkspace()` is the @Observable wrapper. No new moat content; pure orchestration.

**Recommendation: A.** Implement in LeafCore public surface. Method body: read `activeWorkspaceStore.activeWorkspaceID` → call `workspaceService.markLeft(workspaceID:)` → if active workspace was the leaved one, pick first remaining workspace via `listWorkspaces()` → set `activeWorkspaceStore.setActive(_:)` → trigger `refresh()`. If no remaining workspaces → emit empty state.

After leave: `WorkspaceReader.state` transitions to either `.loaded(newActive)` or `.empty`. ProfilView surfaces "You left <workspace>" confirmation banner via `RemovedFromTeamBanner` (existing pattern, repurposed — banner copy: "You left <name>" instead of "Removed from <name>").

**Spec effect:** §9 implementation Step "Leave workspace flow" enumerates the orchestration. Tests: WorkspaceReader.leaveActiveWorkspace() with single-workspace edge case (transitions to .empty), multi-workspace case (auto-switches active), confirmation banner reuse.

---

## B5 — Organization metadata → Settings → Workspace section: full or minimum?

**Q:** OrganizationView currently shows org name + created_at + members + DM entry. After feed subsumes members + DM, what does Settings → Workspace section host?

- **A** Minimum surface — workspace name (read-only display) + created_at + "Leave Workspace" CTA. Members admin (rename / add via invite) defer to S8.
- **B** Full migration — workspace name (editable inline) + members admin (kick / rename teammate / promote-to-admin) + leave + new-workspace CTA.
- **C** Two-tier — basics in Settings, deep admin in dedicated `OrgAdminSheet` triggered from "Manage Members" button.

**Trade-offs:**
- B duplicates S8 explicit scope (per Track 5 contract §4 — "Settings → Workspace (members admin, name) is S8"). Out-of-scope expansion.
- C adds new sheet for stuff explicitly deferred to S8.
- A respects Track 5 sub-phase decomposition.

**Recommendation: A.** Settings → Workspace subsection shows: workspace name (read-only), created date, member count (compact list, no admin actions), [Leave Workspace] destructive CTA. Inline "Workspace admin coming in v1.1" hint for B/C functionality, deferred per §4 to S8.

**Spec effect:** §6 lists new `WorkspaceSettingsSection.swift` in `Leaf/Views/Window/Settings/` (mirrors `ShareControlsSettingsSection.swift` pattern from S5). §3 explicit out-of-scope reaffirms S8 boundary.

---

## OQ-S7-1 — Cross-post badge granularity in feed (M17 inheritor)

**Q:** Recipient sees DM that was also cross-posted (S6 wrote `cross_post_log`). What does badge display?

- **A** Subtle "Also posted elsewhere" — no platform / specifics.
- **B** Per-platform name — "Also posted to Slack" / "Also posted to Linear".
- **C** Full target — "Also posted to #leaf-architecture" / "Also posted as LEA-123".

**Trade-offs (per S6 A13 trust principle):**
- A: zero metadata leak but UX-confusing (where do I find it?).
- B: shows platform without leaking channel/team topology. Sender knew this when toggling cross-post. Privacy posture acceptable.
- C: leaks Slack channel names (recipient may not be in #leaf-architecture and now knows it exists) + Linear issue keys (potentially private projects).

**Recommendation: B.** "Also posted to Slack" / "Also posted to Linear" with no per-target specifics. Rationale: recipient already knows the message exists; cross-post platform is sender-disclosure-grade info ("I broadcast this to wider audience"). Channel/team identity is implementation detail. Future v1.1 transparency-debate may upgrade to C if explicit recipient demand surfaces; downgrade to A trivial.

Visual treatment: subtle inline tag below message body (LeafColor.text.tertiary, LeafType.caption). Multiple platforms → "Also posted to Slack, Linear" (comma-joined).

**Spec effect:** §6 LeafMessageCard sub-view includes optional `crossPostBadge: CrossPostBadge?` model. §9 reader spec: `CrossPostLogReader` actor fetches `cross_post_log` per message_id batch on feed page load (RLS-gated; S6 sender OR recipient JOIN).

---

## OQ-S7-2 — Workspace switcher ordering

**Q:** With N workspaces, switcher list order?

- **A** Alphabetical by workspace name.
- **B** Most-recent-activity (max(`team_events_mirror.server_created_at_ms`, `messages_mirror.server_created_at_ms`) per workspace).
- **C** Pinned (user-marked) → recent activity → alphabetical.
- **D** User-defined drag-to-reorder, persisted in UserDefaults.

**Trade-offs:**
- A simple, predictable but deprioritizes the workspace I'm actually using.
- B matches usage but UI churn (workspace order changes after each ping).
- C / D add UI complexity for marginal MVP value (most users have 1-2 workspaces).

**Recommendation: A (alphabetical).** MVP simplicity. Workspace count typically 1-3 (founder + 1-2 client orgs); ordering rarely matters at this scale. Active workspace already has visual prominence (per OQ-15 active indicator). When user-base grows to 10+ workspaces routinely → revisit with usage data; deferred to v1.1 carry-over.

**Spec effect:** §9 `WorkspaceSwitcherView` sorts `WorkspaceReader.allWorkspaces` by `name.localizedCaseInsensitiveCompare`. Carry-over M1: user-defined ordering for v1.1.

---

## OQ-S7-3 — Unread badge calculation

**Q:** Switcher row shows unread count. What counts as "unread"?

- **A** Unread DMs only (count from `messages_mirror` partial index `idx_messages_mirror_unread`).
- **B** Unread DMs + unseen auto-shared events (require new `team_events_mirror.read_at_ms` column).
- **C** Unread DMs + open Tasks (DMs where `kind='task' AND done_at_ms IS NULL`).

**Trade-offs:**
- B requires schema migration (new column + index) + read-tracking on every team_events scroll → defer.
- C conflates lifecycle states (read = seen-but-not-actioned ≠ unread).
- A clean primitive: badge counts truly-unread DMs. Open Tasks visible as separate icon if needed (out of scope for switcher badge).

**Recommendation: A.** Unread DMs only. SQL: `SELECT workspace_id, COUNT(*) FROM messages_mirror WHERE direction='inbound' AND read_at_ms IS NULL GROUP BY workspace_id`. Existing partial index `idx_messages_mirror_unread` covers query. Refresh cadence: triggered by `DirectMessageInboxReader.tick()` (30s foreground loop already established in S4); reader exposes `unreadCountByWorkspace: [String: Int]` published map for SwiftUI binding.

**Spec effect:** §9 extends `DirectMessageInboxReader` (S4 carry-over surface) with `unreadCountByWorkspace` published map. `LeafWorkspaceSwitcher` row binds to map. Tests: empty workspace → 0; 5 unread → 5; mark one read → 4 (real-time via @Observable).

---

## OQ-S7-4 — Feed sort key

**Q:** Unified feed merges DMs + auto-shared events. Sort key?

- **A** Strict `server_created_at_ms DESC` across both tables (uniform recency).
- **B** Pinned (user-starred) → chronological.
- **C** Group by sender + chronological within group.
- **D** Open Tasks pinned top → chronological rest.

**Trade-offs:**
- B / D require new schema (`messages_mirror.pinned_at_ms` or app-side filter state) — defer post-MVP per session-start.md "search / pinning / archival — post-MVP".
- C breaks chronology (a 1h-old message from Anton appears next to a 5-day-old one) — confusing.
- A: predictable, matches Slack / iMessage / GitHub notification patterns. Universal chronological feed.

**Recommendation: A.** Strict ASC by combined `server_created_at_ms` (DESC for "newest first" display, ASC for storage). SQL union pattern (pseudo): `SELECT 'dm' AS source, server_created_at_ms FROM messages_mirror WHERE workspace_id=? UNION ALL SELECT 'evt' AS source, server_created_at_ms FROM team_events_mirror WHERE workspace_id=? ORDER BY server_created_at_ms DESC LIMIT 50`. Type-safe via `FeedItem` enum (`.directMessage(DirectMessageMirrorRow)` or `.teamEvent(TeamEventMirrorRow)`).

**Spec effect:** §9 `TeamFeedReader` actor exposes `recentItems(workspaceID:, limit:Int = 50, before: Int64? = nil)` returning `[FeedItem]`. Tests: empty workspace → []; 3 DMs + 5 events → 8 items sorted by ts DESC; before=cursor → next page.

---

## OQ-S7-5 — Filter chips set

**Q:** Which filters render above feed?

- **A** Predefined static set: All / Direct messages / Decisions / Blockers / Raw activity.
- **B** Dynamic — chip per ShareSource (9 cases) + per DM kind (3 cases) = 12+ chips, overflow ugly.
- **C** Hierarchical — Top-level (All / DMs / Activity) + drill-down filters in popover.
- **D** Predefined + "More…" overflow with checkboxes for 9 ShareSource cases.

**Trade-offs:**
- B clutter — most users won't filter by `linearIssues` vs `slackMentions` granularly.
- C two-level UX = more clicks for primary use.
- D best of both — common filters one-click; rare filters discoverable.

**Recommendation: D.** Visible chips (single row, no overflow): `All` / `Direct messages` / `Activity` / `Decisions` / `Blockers`. Trailing `… More` chip opens popover with 9 ShareSource toggles for power users (drives multi-select filter state). Chips multi-select via tap (visual: filled vs outlined pill from LeafPill atom).

Selection semantics: All = no filter (default); selecting any other chip narrows. "Direct messages" = source.dm; "Activity" = source.raw (union of git/Linear/Slack base activity); "Decisions" = detected_decision events; "Blockers" = detected_blocker events. Popover toggles individual ShareSources (gitCommits / linearIssues / etc.) for fine-grained tuning.

**Spec effect:** §6 LeafFilterChips API: `init(filters: [FeedFilter], selection: Binding<Set<FeedFilter>>)`. §9 `FeedFilter` enum with cases + computed property mapping to SQL WHERE clause.

---

## OQ-S7-6 — Sticky Send button position

**Q:** Where does the persistent `[+ Send]` button anchor in TeamView?

- **A** Top-right of TeamView toolbar (macOS convention: primary action in toolbar).
- **B** Bottom-right floating FAB.
- **C** Bottom bar fixed.
- **D** Inline in pill-row members area ("+" next to last avatar).

**Trade-offs:**
- B / C iOS-pattern; macOS convention disfavors floating buttons for primary actions.
- D ambiguous semantics (member-add vs send-message).
- A native macOS pattern; toolbar always visible regardless of feed scroll; integrates with `LeafToolbar` substrate.

**Recommendation: A.** Primary `[+ Send]` button anchored top-right in `LeafToolbar` (composes existing atom). Icon `square.and.pencil` + label "Send"; click → presents `SendDirectMessageSheet`. Toolbar also hosts (optional, future): filter chip overflow toggle, workspace context label. Bottom of feed: pagination "Load older" button (per OQ-13).

**Spec effect:** §6 TeamView composition: `LeafToolbar { ... [Send] button ... } → ScrollView { ... feed ... }`. Send sheet trigger lives in toolbar, not body, so visible during scroll.

---

## OQ-S7-7 — Empty state copy + CTA (3 explicit states)

**Q:** 3 empty states per session-start.md. Copy + CTA per state.

**State 1: fresh workspace, no members yet (only self).**
- Copy: "It's quiet here. Invite teammates to start sharing."
- Primary CTA: `[+ Invite teammate]` → opens `GenerateInviteSheet` (existing).
- Secondary text: "You can also send yourself a Handoff to test." → `[+ Send to self]` link.

**State 2: members joined, no activity yet.**
- Copy: "<N> teammates here. Activity will appear as they share."
- Primary CTA: `[+ Send first message]` → opens `SendDirectMessageSheet`.
- Secondary text: "Share Controls: <X of 9 sources enabled>" → link to Settings → Share Controls.

**State 3: filters too restrictive (active filters hide all items).**
- Copy: "No matches for current filter."
- Primary CTA: `[Clear filters]` → resets `selectedFilters` to `[.all]`.
- Secondary text: "<N> items total in this workspace."

**Trade-offs:**
- States 1+2 use existing `LeafEmptyState` atom (matches Track 2 D1 pattern).
- State 3 reuses `LeafEmptyState` with action variant; could be inline banner instead.

**Recommendation: as above** — three explicit states using `LeafEmptyState` atom uniformly. Copy short, action-oriented. State 2 secondary text helps user discover why feed might be sparse (Share Controls denials).

**Spec effect:** §6 TeamView empty-state switch documented with each copy. Tests: each state renders correct copy + CTA wired correctly (snapshot tests deferred to v1.1; SwiftUI Preview suffices for visual review).

---

## OQ-S7-8 — Leave workspace UX

**Q:** Right-click context menu "Leave" — what happens?

- **A** Immediate hide from switcher + soft-mark `left_at_ms` + banner "You left <name>. Data retained 30d." in Profile/Settings.
- **B** Confirmation modal "Leave <name>? You'll stop receiving updates." → confirm → A.
- **C** Soft-mark only (workspace stays in switcher, dimmed "Left" badge).

**Trade-offs:**
- C confusing (UI shows workspace you can't act in).
- A immediate but irreversible-feeling. Data retention banner mitigates.
- B confirmation prevents accidental tap (right-click menus on macOS).

**Recommendation: B with A behavior on confirm.** Confirmation modal:

```
Leave <workspace name>?
You'll stop receiving messages and updates from this team.
Your local message history will remain available for 30 days, then auto-delete.

[Cancel] [Leave Workspace] ← destructive style
```

On confirm: `WorkspaceReader.leaveActiveWorkspace()` (per B4 above) → soft-mark `left_at_ms` → switcher list refreshes (workspace disappears) → active workspace re-resolves (first remaining alphabetical) → feed re-renders. If user was on the leaved workspace, brief in-place banner "You left <name>" auto-dismisses after 3s.

**Spec effect:** §9 implementation step "Leave workspace flow". `LeaveWorkspaceConfirmationModal.swift` new sheet view. Test: confirm path triggers `leaveActiveWorkspace()`; cancel path no-ops; banner auto-dismiss timing.

---

## OQ-S7-9 — Pill-row members overflow when >10

**Q:** Pill-row at top of TeamView. Workspace has 15 members. Render?

- **A** Single-row horizontal scroll (overflow hidden, scrollbar on hover).
- **B** "+5 more" trailing chip → click expands to grid view.
- **C** Wrap to 2-3 rows (LazyVGrid).
- **D** Hide pill-row above 10 members; render compact "Members: 15 →" link to Settings.

**Trade-offs:**
- C breaks visual hierarchy (pill-row should be horizontal scan).
- D loses team-presence glanceable surface.
- A native macOS scroll pattern; works at any count.
- B works but introduces popover state for marginal benefit; first 10 + "+5 more" = still scrolling.

**Recommendation: A.** Horizontal scroll via `ScrollView(.horizontal)` containing `HStack` of member pills. Scroll indicator hidden by default, visible on hover (macOS convention). At 5 members no scroll needed; at 15+ smooth swipe/trackpad/drag. Each pill = `LeafPill` atom with avatar + name.

**Spec effect:** §6 TeamView layout enumerates pill-row as `ScrollView(.horizontal, showsIndicators: false)`. Test: 3 members + 30 members both render without layout overflow.

---

## OQ-S7-10 — Message card actions

**Q:** `LeafMessageCard` inline actions (Mark read / Reply / Mark done for Task). UI pattern?

- **A** Always-visible inline buttons (small icon row below message body).
- **B** Hover-reveal action bar (macOS convention).
- **C** Right-click context menu only (discoverability concern).
- **D** Swipe gesture (iOS pattern; awkward on macOS).

**Trade-offs:**
- D doesn't fit macOS pointing-device interaction.
- C low discoverability for primary actions.
- A clutter for messages that don't need action (Pings auto-mark-read on view).
- B native macOS, clean visual when not hovering, discoverable via cursor proximity.

**Recommendation: B (hover-reveal) + C (right-click) combined.** Hover state reveals contextual action bar (top-right of card overlay): for Handoffs → `[Mark read]` + `[Reply]`; for Tasks (open) → `[Mark done]` + `[Reply]`; for Pings → auto-read on display (no actions). Right-click menu duplicates same actions + adds `[Copy text]` / `[View original event]` if message has attached_external_ref.

Auto-mark-read behavior: card scrolls into view + visible >300ms → `markRead()` called automatically (existing `DirectMessageService.markRead` API). Manual `[Mark unread]` available via right-click.

**Spec effect:** §6 LeafMessageCard API exposes `actions: [MessageAction]` model + hover state binding. §9 implementation: scroll-detection via `GeometryReader` + 300ms debounce timer. Tests: hover state reveals correct actions per kind; auto-read fires after debounce; right-click menu matches hover actions.

---

## OQ-S7-11 — Cross-workspace notification deeplink

**Q:** Click APNs notification from inactive workspace. State machine?

- **A** App activates → `WindowState.section = .team` → `ActiveWorkspaceStore.setActive(messageWorkspaceID)` → scroll to message_id.
- **B** Just activate app; user manually switches workspace.
- **C** Show ephemeral toast "Switch to <workspace> to view this message?" with action.

**Trade-offs:**
- B betrays user expectation (they clicked the notification — show the message).
- C extra friction.
- A respects click intent.

**Recommendation: A.** State machine: APNs delivered → `LeafAppDelegate.userNotificationCenter(_:didReceive:)` extracts `workspace_id` from `userInfo` (S4 already wires thread-id) → posts NotificationCenter event `LeafNotification.deeplink(workspaceID:, messageID:)` → `LeafApp` observer:
1. `ActiveWorkspaceStore.setActive(workspaceID)` — switch active workspace.
2. `WindowState.section = .team` — switch to Team tab.
3. Trigger `DirectMessageInboxReader.tickOnce(workspaceID:, forMessageID:)` — ensure message materialized.
4. Set `TeamView.scrollToMessageID = messageID` — feed auto-scrolls to highlighted message (transient 2s background pulse via `LeafColor.accent.subtle`).

**Spec effect:** §9 implementation step "Deeplink state machine". `WindowState.pendingMessageID: String?` published; TeamView observes + scrolls + animates highlight + clears state.

---

## OQ-S7-12 — Auto-shared event grouping

**Q:** Sender pushes 10 git commits in 5 minutes. Feed render?

- **A** 10 individual rows (chronological, no grouping).
- **B** Group into single row "10 commits by Anton in 5m" → expand on click.
- **C** Group only if >5 same-kind same-sender within 10m window.

**Trade-offs:**
- A overwhelms feed during burst activity.
- B/C: grouping logic = view-layer concern; data model unchanged (events stored individually).

**Recommendation: C.** Threshold: 5 same-kind same-sender events within 10-minute sliding window collapse into single `LeafFeedRow.grouped` variant. Render: "Anton — 10 commits in `gundemtech/leaf`" + chevron → expanded view lists individual commits. Same logic for Linear updates / Slack messages bursts.

Algorithm (in `TeamFeedReader.applyGrouping(_:)`): scan items chronologically; when count of (kind, sender_pubkey) within 10m window ≥ 5, collapse contiguous slice. Single-item slices unchanged.

**Spec effect:** §9 `TeamFeedReader` exposes `recentItemsGrouped(workspaceID:, ...)`. `FeedItem.grouped(kind:, sender:, count:, expandedItems:)` enum case. Tests: 4 commits → 4 rows (no group); 5 commits → 1 group; 10 commits + 1 PR → group + separate PR row; 5 commits then 30m gap then 5 more → 2 separate groups.

---

## OQ-S7-13 — Feed pagination

**Q:** Memory implications of unbounded feed scroll on N-week-old `messages_mirror` + `team_events_mirror`.

- **A** Infinite scroll with virtualization (`LazyVStack` + load-more-on-bottom).
- **B** Explicit `[Load older]` button at feed bottom.
- **C** Page size 50 + "View all" link to dedicated archive.

**Trade-offs:**
- C splits surface, defers archive UI build.
- B explicit but interrupts scroll flow.
- A native macOS feed pattern (Mail, Slack, iMessage); SwiftUI `LazyVStack` handles row recycling free.

**Recommendation: A with bounded page size.** `TeamFeedReader.recentItems(workspaceID:, limit: 50, before: Int64?)`. SwiftUI `LazyVStack` renders only visible rows. Bottom sentinel view (`.onAppear`) triggers next page load via `loadOlder(before: lastItemTs)`. Loading spinner appears as last row during fetch. When `before` query returns < 50 → reached oldest, no more pagination.

Memory ceiling: typical workspace ~30 events/day × 90d retention (team_events) + ~5 DMs/day forever = ~3000 items max in mirror. `LazyVStack` recycles offscreen rows → constant memory regardless of scroll depth.

**Spec effect:** §9 `TeamFeedReader.loadOlder(before:)` method. TeamView pagination state in @State. Test: scroll to bottom → loadOlder fires; 0-item response → spinner hidden, no infinite-loop.

---

## OQ-S7-14 — Cross-post status in sender's OWN feed view

**Q:** Sender (Anton) sent a DM cross-posted to Slack. Does Anton's feed view show "Posted to Slack" badge on his own outbound message?

- **A** Show badge — symmetric with recipient view (OQ-1 B applies both directions).
- **B** Hide badge — sender already saw status in Send sheet confirmation flow; redundant noise.
- **C** Show badge only when failed (e.g., "Linear post failed — Retry").

**Trade-offs:**
- B inconsistent with recipient view (visual mismatch in shared screens).
- C optimizes for failure case; missed-success-confirmation acceptable.
- A consistent + reinforces "this was broadcast" awareness.

**Recommendation: A.** Symmetric badge on sender's outbound + recipient's inbound. Same component (`crossPostBadge`). Cost: zero — same `cross_post_log` query covers both directions (RLS already sender OR recipient).

Failure case (M19 / C variant): if `cross_post_log.error_text IS NOT NULL`, badge renders as "⚠ Linear post failed". Click → retry sheet (future v1.1 per S6 carry-over M4). MVP: failure badge shows error_text on hover tooltip.

**Spec effect:** §6 LeafMessageCard shows crossPostBadge for both directions. §9 `CrossPostLogReader.fetch(messageIDs:)` returns map regardless of direction.

---

## OQ-S7-15 — Active workspace indicator visual style

**Q:** Switcher row visually distinguishes active workspace. Treatment?

- **A** Filled circle indicator (left of row).
- **B** Accent border around active row.
- **C** Left edge stripe (4pt vertical bar in accent color).
- **D** Bold typography on active workspace name.

**Trade-offs:**
- D too subtle, fails glance test.
- B busy visual (each member row already has card-style border).
- C compact, hierarchical (matches macOS sidebar active-item conventions — see Finder, Mail).
- A separate visual element competes with avatar.

**Recommendation: C.** 4pt left-edge vertical stripe in `LeafColor.accent.emphasis`. Matches macOS sidebar nav-active patterns (NSOutlineView). Visible peripherally without explicit attention. Combined with `LeafType.bodyEmphasis` on workspace name (slight weight bump) for additive cue.

**Spec effect:** §6 LeafWorkspaceSwitcher row anatomy: 4pt accent stripe (visible only when isActive) + avatar + name (emphasis if active) + unread badge. §11 token usage explicit.

---

## OQ-S7-16 — Realtime mirror updates

**Q:** S4 inbox tick + S5 mirror tick = 30s foreground polling. S7 feed wants faster refresh?

- **A** Keep 30s; rely on scenePhase=.active trigger + manual pull-to-refresh.
- **B** Decrease to 10s in TeamView only (other tabs stay 30s).
- **C** WebSocket subscription via Supabase Realtime channel (`team_events_mirror` + `messages_mirror`).

**Trade-offs:**
- C adds Supabase Realtime dependency (new transport layer; CPU + battery cost; complex retry); out of scope for S7.
- B premature optimization — 30s feels fine for chat-like surface.
- A respects S4/S5 substrate timing; adds explicit foreground-active boost.

**Recommendation: A with foreground-active eager tick.** Keep 30s baseline (already in OrganizationView per Discovery). On `scenePhase` becomes `.active` AND TeamView is current section → fire immediate `tick()` to catch up after sleep/inactive. Manual pull-to-refresh via toolbar `[Refresh]` icon button (subtle, rarely needed).

Supabase Realtime explicit non-goal for S7 (carry-over Track 6 if user feedback demands sub-30s latency). Rationale: 30s feels native for team-async surface; users typically don't refresh-spam Slack threads either.

**Spec effect:** §9 TeamView `.onChange(of: scenePhase)` triggers `inboxReader.tick()` + `mirrorReader.tick()` when becoming active. Carry-over M2: Supabase Realtime in Track 6.

---

## OQ-S7-17 — Linked event preview rendering

**Q:** DM has attached event (`attachment_kind="github_pr"`, `attachment_external_ref="gundemtech/leaf#142"`). Feed renders?

- **A** Inline text reference — "Linked: gundemtech/leaf#142" plain.
- **B** Compact embedded card with title/status (requires fetching PR metadata via collector / API).
- **C** Clickable text → opens external URL in browser.

**Trade-offs:**
- B requires extra fetch + new UI atom + integration with existing collectors → significant scope.
- A informationless.
- C minimal value-add but no new fetch + matches expected behavior.

**Recommendation: C for S7; B carry-over to S8/Track 6.** Render attachment as clickable `LeafIconLabel` row: GitHub icon + "gundemtech/leaf#142" link. Click → `NSWorkspace.shared.open(URL(...))` → opens browser. URL construction per attachment_kind (GitHub: `https://github.com/<external_ref_to_path>`; Linear: `https://linear.app/<workspace>/issue/<id>`).

Compact embed card (with PR title / status / author) deferred to S8 polish or Track 6 (needs LinearCollector + GitHubCollector hooks for metadata fetch — out of S7 scope per session-start.md "Out of scope: rich linked event previews").

**Spec effect:** §6 LeafMessageCard `attachmentView: AttachmentView?` sub-view = LeafIconLabel + click handler. §9 `AttachmentURLBuilder` helper maps `(kind, external_ref) → URL`. Tests: GitHub URL composition; Linear URL composition; unknown kind → no row.

---

## Summary — design calls affecting spec

| Area | Status | Spec section to update |
|---|---|---|
| B1 | Decided: A (TeamView refactor in place) | §3 architecture; §6 nav structure |
| B2 | Decided: 2 Layouts + 2 Composites | §7 file layout |
| B3 | Decided: A (preserve S6 closure injection) | §9 sheet trigger relocation |
| B4 | Decided: A (LeafCore public) | §9 leaveActiveWorkspace impl |
| B5 | Decided: A (minimum Settings surface) | §6 WorkspaceSettingsSection |
| OQ-1 | Decided: B (per-platform badge) | §6 LeafMessageCard crossPostBadge |
| OQ-2 | Decided: A (alphabetical) | §9 switcher sort; M1 carry-over |
| OQ-3 | Decided: A (unread DMs only) | §9 unreadCountByWorkspace |
| OQ-4 | Decided: A (strict chronological DESC) | §9 TeamFeedReader |
| OQ-5 | Decided: D (predefined + "More") | §6 LeafFilterChips API |
| OQ-6 | Decided: A (top-right toolbar) | §6 TeamView layout |
| OQ-7 | Decided: 3 explicit empty states with action CTAs | §6 empty switch |
| OQ-8 | Decided: B (confirmation modal + soft-mark) | §9 LeaveWorkspaceConfirmationModal |
| OQ-9 | Decided: A (horizontal scroll) | §6 pill-row layout |
| OQ-10 | Decided: B+C (hover-reveal + right-click) | §6 LeafMessageCard actions |
| OQ-11 | Decided: A (auto-switch deeplink) | §9 deeplink state machine |
| OQ-12 | Decided: C (5+ same-kind/sender/10m → group) | §9 TeamFeedReader grouping |
| OQ-13 | Decided: A (LazyVStack + pagination 50) | §9 loadOlder pagination |
| OQ-14 | Decided: A (symmetric badge sender+recipient) | §6 LeafMessageCard cross-direction |
| OQ-15 | Decided: C (4pt accent left edge stripe) | §6 LeafWorkspaceSwitcher row |
| OQ-16 | Decided: A + scenePhase eager (30s baseline) | §9 scenePhase tick; M2 carry-over |
| OQ-17 | Decided: C for S7; B deferred | §6 attachmentView; carry-over |

**Net spec deltas:** 22 areas resolved. New components: `LeafMessageCard`, `LeafFeedRow`, `LeafWorkspaceSwitcher`, `LeafFilterChips`, `WorkspaceSettingsSection`, `LeaveWorkspaceConfirmationModal`. New readers: `TeamFeedReader`, `CrossPostLogReader`. Reader extensions: `DirectMessageInboxReader.unreadCountByWorkspace`. App-state additions: `WindowState.pendingMessageID`. Carry-overs: M1 (user-defined switcher ordering v1.1), M2 (Supabase Realtime v1.1), M3 (rich linked event preview S8/Track 6), M4 (workspace admin S8).

**Out-of-scope reaffirmed:** Settings → Workspace deep admin (S8), Privacy section (S8), MCP `leaf_query_team` (S8), tier-gating (S8), per-recipient share rules (Track 6), time-bounded sharing (Track 6), Share Controls presets (out of MVP), iOS port (post-MVP), search / pinning / archival in feed (post-MVP), Supabase Realtime (Track 6 carry-over), rich linked event preview cards (S8/Track 6).
