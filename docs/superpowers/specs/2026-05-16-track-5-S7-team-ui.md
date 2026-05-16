# Track 5 / S7 — Team UI Redesign + Multi-Workspace

> **Type:** Phase implementation spec (Stage 3 of 8-stage workflow per `conventions.md`).
> **Track 5 contract:** `2026-05-13-track-5-collaboration-contract.md` — §4 sub-phase decomposition, §7 UI surface contract, §14 multi-workspace.
> **Predecessor specs:** S2 (`2026-05-14-track-5-S2-multiworkspace-substrate.md`), S4 (`2026-05-14-track-5-S4-direct-messages.md`), S5 (`2026-05-15-track-5-S5-auto-share.md`), S6 (`2026-05-16-track-5-S6-cross-post.md`).
> **Brainstorm:** `2026-05-16-track-5-S7-team-ui-alternatives.md` — 22 areas; resolved per Amendment 2026-05-16.
> **Branch:** `feature/track-5-S7-team-ui` (off S6 `cee9ac0`).
> **Plan handoff:** `docs/superpowers/plans/2026-05-16-track-5-S7-team-ui.md` (gitignored — tactical impl with moat-sensitive params).

---

## §1 Purpose

S7 unifies Team-facing surfaces into a single feed + introduces the multi-workspace switcher UI. Replaces `OrganizationView` (current MVP placeholder) with a real chronological feed merging direct messages (S4 substrate) + auto-shared events (S5 substrate) + cross-post status badges (S6 substrate). Adds sidebar-bottom workspace switcher (data model from S2) and migrates workspace metadata + members admin to Settings.

**Closes UC-T5-6** (Multi-workspace switcher — sidebar bottom shows both workspaces with avatar + name + unread badge; click switches active workspace; Team tab feed updates; notifications labelled `[<workspace>]`).

**Partially closes UC-T5-2** (Auto-share AI query surface — Team feed renders auto-shared events with sender attribution; `leaf_query_team` MCP tool deferred to S8).

**Partially closes UC-T5-3/4/5** (DM display + cross-post status badges per S6 M17 carry-over).

**Substrate inherited unchanged:** S2 workspaces table + per-workspace TeamKeystore; S4 `messages_mirror` + `DirectMessageInboxReader` + APNs flow; S5 `team_events_mirror` + `TeamEventMirrorReader` + ShareRulesReader + Share Controls UI; S6 `cross_post_log` + Cross-post UI components.

---

## §2 Goal — fitness function

**Acceptance signals (pass = S7 ships):**

1. **Unified feed renders correctly.** TeamView shows chronological-DESC merge of `messages_mirror` + `team_events_mirror` within active workspace; filter chips constrain to selected source types; empty states cover three explicit cases (fresh / no-activity / filters-too-restrictive).
2. **Workspace switcher works.** Sidebar bottom lists all non-left workspaces alphabetically; active workspace marked with filled checkmark + emphasis text; unread DM count badge per workspace; click switches `ActiveWorkspaceStore.activeWorkspaceID`; Team / Connections / Settings tabs re-render with new workspace context within 200ms (perceptual «instant»).
3. **Realtime updates feed.** Inserting a `team_events` row in Supabase from teammate's Mac → mirror UPSERT + feed re-render on local Mac ≤ 2s (target: P95 < 1500ms; allows for WS RTT + decrypt + render). When WS disconnected → fallback 30s polling reconciliation preserves correctness.
4. **Settings → Workspace replaces OrganizationView.** OrganizationView.swift deleted (zero compile-time refs). Settings hosts workspace name (editable) + members list with kick action (admin only) + pending invites + leave + delete (admin only) + new-workspace.
5. **Send sheet relocated to TeamView toolbar.** S6 closure injection preserved; `[+ Send]` button top-right + `⌘N` shortcut + sheet body unchanged.
6. **Cross-post badges render.** DM with cross-post entries shows clickable `LeafLinkedEventCard` per platform (Slack channel name or Linear issue key) below message body; click → external URL.
7. **Linked event embed renders.** DM with `attachment_external_ref` shows `LeafLinkedEventCard` with cached metadata (title + status + author) or `Loading…` placeholder + fetch on miss.
8. **Token discipline preserved.** `just check-tokens` passes BASE+MIGRATION+RETIRED tiers across all new/modified UI files. No hardcoded colors/spacing/typography.
9. **Test baseline grows green.** S6 baseline ~2320 SPM tests → S7 ~2460 (estimated +140 across new readers/services/atoms/feed merge logic — itemized breakdown in §14). 5/5 xcodebuild schemes compile green (Leaf + LeafAgent + LeafCore + LeafCorePrivate + LeafMCP, no-sign dev config).
10. **Deeplink works.** APNs notification click from inactive workspace → app activates → switches to message's workspace → scrolls to message + transient highlight.

**Manual smoke G19** verifies signals 1-10 end-to-end on two-Mac signed-build session (alongside S3 G15+G16, S4 G21, S5 G18, S6 G18). See §13.

---

## §3 Out of S7 scope

Per Track 5 contract §4 sub-phase decomposition + `track-5-S7-session-start.md` boundary statements:

**Reserved for S8:**
- Member promote/demote (requires `workspace_members.role` column — schema work)
- Privacy section (read-only deny-list inspector UI)
- `leaf_query_team` MCP tool (Layer C-style cross-workspace query)
- Tier-gating UI (Free vs Team CTA — billing track)

**Reserved for Track 6:**
- Per-recipient share rules (current S5 share rules are workspace-wide)
- Time-bounded sharing with countdown («share to Anton for next 2h»)

**Out of MVP entirely:**
- Share Controls presets («Default team» / «Privacy-paranoid» / «Pair-programming»)
- iOS port
- Search in feed (post-MVP carry-over)
- Pinning messages (post-MVP)
- Archival (post-MVP)
- Reactions on DMs (requires schema; out of scope)
- Typing indicators (not applicable — structured Send sheet, not freeform chat)

**Carry-over deferred (post-S7, pre-Track 6):**
- M1 user-defined workspace switcher ordering (drag-reorder)
- M4 member promote/demote (S8)
- M6 ShareSource filter persistence cross-device (currently per-device UserDefaults)

---

## §4 Architecture overview

S7 is **rendering-layer composition** on top of S2-S6 data substrate, plus one new transport layer (Realtime) and one new service (cross-post log fetcher).

### 4.1 View topology change

**Before S7:**
```
LeafApp
├── RootView
│   ├── Sidebar (LEAF / COLLABORATION / ACCOUNT)
│   │   └── nav items: home, activity, team, connections, organization, settings, profile
│   └── detail switch on WindowState.section
│       ├── .team → TeamView (adaptive grid of members)
│       └── .organization → OrganizationView (org card + members + DM entry)
└── MenuBarExtra
```

**After S7:**
```
LeafApp
├── RootView
│   ├── Sidebar (LEAF / COLLABORATION / ACCOUNT)
│   │   ├── nav items: home, activity, team, connections, settings, profile (— organization)
│   │   └── LeafWorkspaceSwitcher (bottom-anchored, full-width)
│   └── detail switch on WindowState.section
│       └── .team → TeamView (refactored — unified feed)
│           ├── LeafToolbar (top — [+ Send] button + ⌘N shortcut)
│           ├── pill-row members ScrollView(.horizontal)
│           ├── LeafFilterChips (5 visible + «More» popover)
│           ├── feed body (LazyVStack of FeedItem)
│           │   ├── LeafMessageCard (for DMs — outbound or inbound)
│           │   ├── LeafFeedRow (for individual auto-shared events)
│           │   ├── LeafFeedRow.grouped (for 5+ same-kind/sender/15m bursts)
│           │   └── 3 empty states (LeafEmptyState variants)
│           └── pagination sentinel (LazyVStack onAppear → loadOlder)
└── MenuBarExtra (unchanged)
```

`OrganizationView.swift` deleted entirely. Its `.organization` nav item removed from Sidebar. Onboarding `.team` step + invite/accept flows continue to use existing `GenerateInviteSheet` + `AcceptInviteSheet`.

### 4.2 Reader topology

**New readers — placement convention.**

Existing precedent (per Discovery): app-level `@MainActor @Observable` reader wrappers live in `Leaf/Models/` (e.g., `Leaf/Models/DirectMessageInboxReader.swift`, `Leaf/Models/TeamEventMirrorReader.swift`, `Leaf/Models/WorkspaceReader.swift`). Underlying services live in `Packages/LeafCore/Sources/LeafCore/Team/*Service.swift` as `struct Sendable` or `actor`. SwiftUI binds readers directly; readers delegate to services for off-main I/O.

S7 new types follow this split:

- `TeamFeedReader` (`Leaf/Models/TeamFeedReader.swift`) — `@MainActor @Observable final class`. Composite query merging `messages_mirror` + `team_events_mirror` filtered by active workspace + selected filters. Paginated. Delegates SQL to new `TeamFeedQueryService` actor in `Packages/LeafCore/Sources/LeafCore/Team/TeamFeedQueryService.swift`. Exposes `loadInitial / loadOlder / refresh / applyGrouping` (5+/15m threshold).
- `CrossPostLogReader` (`Leaf/Models/CrossPostLogReader.swift`) — `@MainActor @Observable final class`. Wraps `SupabaseClient.fetchCrossPostLog(messageIDs:)` calls (SupabaseClient is already `actor` per `Packages/LeafCore/Sources/LeafCore/Network/SupabaseClient.swift:17`). Caches by message_id; refreshes when feed page loads or new DM arrives. Exposes `crossPosts(for messageID:) -> [CrossPostLogRow]`.
- `AttachmentMetadataResolver` (`Packages/LeafCore/Sources/LeafCore/Team/AttachmentMetadataResolver.swift`) — pure `actor` (not @Observable). Used internally by feed render path. Resolves `(provider, external_ref) -> AttachmentMetadata` via local `events` table lookup first, then collector fetch fallback. Cache TTL: 5min. Exposes `resolve(provider:, externalRef:) async -> AttachmentMetadata?`.
- `LeafRealtimeService` (`Leaf/Models/LeafRealtimeService.swift`) — `@MainActor @Observable final class` for connection state visibility. Wraps internal `actor RealtimeWebSocketDriver` (in `Packages/LeafCore/Sources/LeafCore/Network/RealtimeWebSocketDriver.swift`) that owns `URLSessionWebSocketTask` + Phoenix channel state + reconnect state machine. Subscribes to 2 channels (`team_events` INSERT + `direct_messages` INSERT/UPDATE) filtered by active `workspace_id`. On push → invokes corresponding mirror service `absorbRealtimePush(rawRow:)`.

Rationale for split: UI-bound observables in app target (`Leaf/`); pure I/O actors + value types in LeafCore (reusable by Agent / MCPServer processes if needed in future).

**Reader extensions:**

- `DirectMessageInboxReader.unreadCountByWorkspace: [String: Int]` — new published map alongside existing `unreadCount: Int` (current per-active-workspace count). Computed via SQL `SELECT workspace_id, COUNT(*) FROM messages_mirror WHERE direction='inbound' AND read_at_ms IS NULL GROUP BY workspace_id`. New method `refreshUnreadCounts()` invoked from existing `tick()` post-success + on Realtime push absorption. Existing `tick()` signature (no args; reads `activeWorkspaceStore` internally) preserved.
- `WorkspaceService` (struct Sendable, sync) gains: `updateName(workspaceID:String, newName:String) throws` (local UPDATE), `softDelete(workspaceID:String, at:Date) throws` (local UPDATE setting `deleted_at_ms` + cascade local DELETE of workspace-scoped rows + keystore directory removal). Server-side PATCH/DELETE is orchestrated separately via `SupabaseClient`.
- `SupabaseClient` (actor) gains: `patchWorkspaceName(id:String, name:String) async throws`, `softDeleteWorkspace(id:String) async throws` — RLS-gated PATCH on `workspaces` table.
- `WorkspaceReader` (Leaf/Models, `@MainActor @Observable`) gains: `func rename(workspaceID:String, newName:String) async` (orchestrates Supabase PATCH then `WorkspaceService.updateName` then `refresh()`), `func delete(workspaceID:String) async` (admin-only; orchestrates `SupabaseClient.softDeleteWorkspace` then `WorkspaceService.softDelete` then re-resolve active workspace via `ActiveWorkspaceStore.setActive`), `func leaveActiveWorkspace() async` (implements NIT-3 carry-over from S2: soft-mark current workspace's `left_at_ms` via existing `WorkspaceService.markLeft`, re-resolve active to next alphabetical, transition state to `.loaded(newActive)` or `.empty`).
- `ActiveWorkspaceStore` unchanged (existing `setActive(_:)` already suffices).

### 4.3 View hierarchy detail (TeamView refactor)

```
TeamView (entry point — replaces OrganizationView surface)
└── ZStack
    ├── content (state switch)
    │   ├── loading → ProgressView centered
    │   ├── empty (no members) → LeafEmptyState (state 1 from §6.4)
    │   ├── loaded → VStack
    │   │   ├── LeafToolbar { Spacer; LeafButton.primary "[+ Send]" }
    │   │   ├── pill-row members (ScrollView horizontal)
    │   │   ├── LeafFilterChips
    │   │   ├── ScrollView vertical (LazyVStack feed)
    │   │   │   └── ForEach FeedItem → cardView(for: item)
    │   │   ├── if no items after filter → LeafEmptyState (state 3)
    │   │   └── if has items but feed at oldest → small caption «End of history»
    │   └── error → LeafBanner.danger inline
    └── sheets ($sendSheetPresented, $leaveConfirm, etc.)
```

`cardView(for:)` dispatches by `FeedItem`:
- `.directMessage(row)` → `LeafMessageCard(row: row, actions: messageActions(for: row))`
- `.teamEvent(row)` → `LeafFeedRow(row: row)`
- `.grouped(kind:, sender:, count:, expandedItems:)` → `LeafFeedRow.grouped(...)` with chevron-expand state

### 4.4 Composition root changes

`Leaf/LeafApp.swift` additions (alongside existing 20+ readers per Discovery line 14-75):
- `@State private var teamFeedReader: TeamFeedReader`
- `@State private var crossPostLogReader: CrossPostLogReader`
- `@State private var attachmentMetadataResolver: AttachmentMetadataResolver`
- `@State private var realtimeService: LeafRealtimeService`

Injection chain (in `LeafApp.init`, after existing reader composition at line ~146):

```swift
let attachmentResolver = AttachmentMetadataResolver(databaseURL: dbURL, collectorsRegistry: collectorsRegistry)
let teamFeed = TeamFeedReader(
    databaseURL: dbURL,
    databaseEncryption: encryptionOptions,
    attachmentResolver: attachmentResolver,
    activeWorkspaceStore: active
)
let crossPostLog = CrossPostLogReader(supabase: supabase)
let realtime = LeafRealtimeService(
    supabase: supabase,
    activeWorkspaceStore: active,
    directMessageInboxReader: inboxReader,
    teamEventMirrorReader: teamEventMirrorReader,
    crossPostLogReader: crossPostLog
)

_attachmentMetadataResolver = State(initialValue: attachmentResolver)
_teamFeedReader = State(initialValue: teamFeed)
_crossPostLogReader = State(initialValue: crossPostLog)
_realtimeService = State(initialValue: realtime)
```

Window scene `.environment()` chain extended with 4 new readers. `MenuBarExtra` does not consume any of these (menu bar stays minimal — Team feed lives in window).

Lifecycle (in `RootView` or `TeamView`):

```swift
.task(id: activeWorkspaceStore.activeWorkspaceID) {
    if let wid = activeWorkspaceStore.activeWorkspaceID {
        await realtimeService.subscribe(workspaceID: wid)
        await teamFeedReader.loadInitial(workspaceID: wid, filters: filterStore.selected)
    }
}
.onChange(of: scenePhase) { _, phase in
    if phase == .active { Task { await realtimeService.resume() } }
    else { Task { await realtimeService.suspend() } }
}
.onDisappear {
    Task { await realtimeService.unsubscribe() }
}
```

Reader cross-talk: `LeafRealtimeService` accepts existing reader handles by reference so it can call `inboxReader.absorbRealtimePush(_:)` + `teamEventMirrorReader.absorbRealtimePush(_:)` + `crossPostLogReader.absorbRealtimePush(_:)` from incoming WS messages — new public methods added to each reader per §7.5.

### 4.5 Filter state model

```swift
enum FeedFilter: Hashable {
    case all                              // default — no constraint
    case directMessages                   // FeedItem.directMessage(_)
    case openTasks                        // .directMessage where kind=task AND done_at_ms IS NULL AND recipient_pubkey=me
    case decisions                        // .teamEvent where source_kind=detectedDecisions
    case blockers                         // .teamEvent where source_kind=detectedBlockers
    case shareSource(ShareSource)         // .teamEvent where source_kind == arg (from «More» popover)
}

@MainActor @Observable
final class FeedFilterStore {
    var selected: Set<FeedFilter> = [.all]   // multi-select
    func toggle(_ f: FeedFilter) { ... persist UserDefaults[<wid>] ... }
    func clearAll() { selected = [.all] }
}
```

Persisted per-workspace: `UserDefaults.standard.set([codedFilters], forKey: "leaf.feedFilters.<wid>")`. Restored on workspace switch via `task(id:)` reload.

---

## §5 Schema changes

### 5.1 On-device (SQLCipher)

**M025 — workspace soft-delete column + partial-active index.** New migration following existing M001-M024 pattern in `Packages/LeafCore/Sources/LeafCore/DB/Migrations/M025_WorkspaceSoftDelete.swift`:

```swift
extension DatabaseMigrator {
    mutating func registerMigration025WorkspaceSoftDelete() {
        registerMigration("025_workspace_soft_delete") { db in
            // workspaces.name already TEXT NOT NULL per S2 M019 — UPDATE-mutable.
            try db.alter(table: "workspaces") { t in
                t.add(column: "deleted_at_ms", .integer)  // nullable; non-null = soft-deleted
            }
            // Partial index for hot-path "list active workspaces" query
            try db.create(
                index: "idx_workspaces_active",
                on: "workspaces",
                columns: ["id"],
                condition: Column("deleted_at_ms") == nil && Column("left_at_ms") == nil
            )
        }
    }
}
```

Register in `Database.swift` after `registerMigration024TeamEventBroadcastOffsets()`.

**Why:** `WorkspaceService.deleteWorkspace` needs soft-delete column for audit + 30d retention before hard purge (cron prunes via S5 retention pattern). Hard-delete on local row would prevent realtime push handling for in-flight events that arrived after delete-initiation.

**Index rationale:** `WorkspaceReader.listActiveWorkspaces()` query filters by `deleted_at_ms IS NULL AND left_at_ms IS NULL`; partial index speeds common path.

### 5.2 Supabase migration

**M025 (server-side):** Cross-platform sibling.

```sql
-- 20260516120200_workspace_soft_delete_s7.sql
ALTER TABLE workspaces
    ADD COLUMN IF NOT EXISTS deleted_at_ms bigint;

CREATE INDEX IF NOT EXISTS idx_workspaces_active
    ON workspaces (id)
    WHERE deleted_at_ms IS NULL;

-- RLS: existing workspaces_select policy (workspace_member visibility) unchanged.
-- Add: only creator can soft-delete.
CREATE POLICY workspaces_delete_creator ON workspaces
    FOR UPDATE
    USING (created_by_pubkey = (auth.jwt() ->> 'pubkey'))
    WITH CHECK (created_by_pubkey = (auth.jwt() ->> 'pubkey'));

-- Rename: workspace name editable by creator only.
-- Existing UPDATE policy if any — verify. If none exists, add:
-- (covered by above creator-update policy combined; column-level grants not used)
```

**pgTAP test file:** `200_workspace_soft_delete_s7.test.sql` — assertions:
1. Migration applies clean (column + index).
2. Soft-delete UPDATE by creator pubkey allowed.
3. Soft-delete UPDATE by non-creator member rejected (RLS 42501).
4. SELECT visibility unchanged after soft-delete (filter pushed to client; design choice — clients see soft-deleted workspaces in audit, hide in normal UI via `deleted_at_ms IS NULL` filter).

### 5.3 No other on-device migrations

`messages_mirror` (M020), `apns_token_local` (M021), `share_rules` (M022), `team_events_mirror` (M023), `team_event_broadcast_offsets` (M024) — all stay as-is. (Note: actual M020-M024 ordering per `Packages/LeafCore/Sources/LeafCore/DB/Database.swift:58-62`; current-state.md mentions «M020-M024» without exact assignment per index — this spec uses canonical migration file names.)

**Total SQLCipher tables after S7:** unchanged from S6 baseline (`current-state.md` cites "33 SQLCipher tables M001-M024" — M025 only adds column `deleted_at_ms` + partial index `idx_workspaces_active`, no new table). Migration count progresses: M001..M025.

---

## §6 UI surface contract

### 6.1 New atoms

#### LeafMessageCard (Layouts/)

DM card composing avatar + sender name + kind icon + body excerpt + timestamp + optional `crossPostBadge` + optional `attachmentView` + hover-reveal actions overlay.

**Public API:**

```swift
public struct LeafMessageCard: View {
    public let row: DirectMessageMirrorRow
    public let direction: DirectionUI       // .outbound (right-aligned) | .inbound (left-aligned)
    public let crossPosts: [CrossPostLogRow]
    public let attachmentMetadata: AttachmentMetadata?
    public let actions: [MessageAction]    // [.markRead, .reply, .markDone, .copyText, .viewOriginal]
    public let onAction: (MessageAction) -> Void
    public let onAppear: () -> Void        // hosted scroll-detection wrapper signals visible

    public init(...) { ... }
    public var body: some View { ... }
}

public enum DirectionUI { case outbound, inbound }
public enum MessageAction { case markRead, markUnread, reply, markDone, copyText, viewOriginal }
```

**Visual anatomy:**
- LeafCard.raised container
- Top row: HStack { LeafAvatar(member: sender) [size: .small], sender display name (LeafType.bodyEmphasis), kind icon (handoff `figure.run.motion` / task `checklist` / ping `bell`, accent color), Spacer, timestamp («2m ago» — LeafType.caption, text.tertiary) }
- Body: `Text(row.body)` — LeafType.body, max 6 lines (truncate with «…»)
- crossPostBadge (if any): inline HStack of `LeafLinkedEventCard.compact` per cross-post entry — clickable to platform URL
- attachmentView (if `row.attachment_external_ref` set): `LeafLinkedEventCard.full` — clickable to event URL
- Bottom: HStack { read-receipt («Read 2m ago» if outbound + recipient marked read), Spacer, action overlay (hover-reveal, top-right anchored) }
- Hover overlay: HStack of icon buttons (size .small) for each `MessageAction`
- Right-click context menu: same actions + extras (copy text, view original event)

**Auto-mark-read behavior:**
Wrapper view sits inside `GeometryReader`. `.onAppear` starts a 1500ms timer; `.onDisappear` cancels it. On timer fire (still visible) → fires `onAppear` callback → host calls `DirectMessageService.markRead(messageID:)`.

#### LeafFeedRow (Layouts/)

Compact row for individual auto-shared events. Two variants: single + grouped.

**Public API:**

```swift
public struct LeafFeedRow: View {
    public let row: TeamEventMirrorRow
    public let attachmentMetadata: AttachmentMetadata?
    public let onTap: () -> Void

    public init(...) { ... }
    public var body: some View { ... }

    public static func grouped(
        kind: String,
        sender: TeamMember,
        count: Int,
        spanStart: Int64,
        spanEnd: Int64,
        expandedItems: [TeamEventMirrorRow],
        isExpanded: Binding<Bool>
    ) -> some View { ... }
}
```

**Visual anatomy (single):**
- HStack: source-kind icon (SF Symbol mapped per source_kind), sender display name (LeafType.bodyEmphasis), action text («pushed commit «fix typo» to gundemtech/leaf» — derived from payload), Spacer, timestamp.

**Visual anatomy (grouped):**
- HStack: aggregate icon (same as kind), sender name, action text («pushed 10 commits to gundemtech/leaf»), Spacer, timeline span («5m ago — 18m ago» — LeafType.caption), chevron (`chevron.right` rotated 90deg if expanded).
- Tap row → toggle `isExpanded` → withAnimation reveals inline `VStack` of individual rows.

#### LeafWorkspaceSwitcher (Composites/)

Sidebar-bottom list of workspaces + active indicator.

**Public API:**

```swift
public struct LeafWorkspaceSwitcher: View {
    public let workspaces: [Workspace]           // already sorted alphabetically
    public let activeWorkspaceID: String?
    public let unreadCounts: [String: Int]       // workspace_id → unread count
    public let onSelect: (String) -> Void
    public let onAddNew: () -> Void
    public let onLeave: (String) -> Void          // right-click action
    public let onMarkAllRead: (String) -> Void

    public init(...) { ... }
    public var body: some View { ... }
}
```

**Visual anatomy:**
- VStack(spacing: LeafSpace.xs) {
    - ForEach workspaces {
        - HStack(spacing: LeafSpace.sm) {
            - Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
              .foregroundStyle(isActive ? LeafColor.accent.primary : LeafColor.text.tertiary)
            - LeafAvatar(workspace: ws) [size: .xs]
            - Text(ws.name)
              .font(isActive ? LeafType.bodyEmphasis : LeafType.body)
              .foregroundStyle(ws.leftAtMs != nil ? LeafColor.text.tertiary : LeafColor.text.primary)
            - Spacer
            - if unreadCount > 0 {
                LeafBadge(count: unreadCount, kind: .accent)
            }
        }
        .contentShape(.rect)
        .contextMenu { /* Mark all read, Leave */ }
        .onTapGesture { onSelect(ws.id) }
    - }
    - Divider().opacity(0.3)
    - HStack { Image(systemName: "plus.circle"); Text("Add workspace") }.onTapGesture { onAddNew() }
- }
- .padding(LeafSpace.md)
- .background(LeafColor.surface.inset)

**Tokens file:** `LeafWorkspaceSwitcherTokens.swift` — width: full sidebar, row height: 32pt, avatar size: .xs (16pt), spacing: LeafSpace.sm, etc.

#### LeafFilterChips (Composites/)

Horizontal pill row with multi-select + «More…» overflow.

**Public API:**

```swift
public struct LeafFilterChips: View {
    public let visibleFilters: [FeedFilter]      // [.all, .directMessages, .openTasks, .decisions, .blockers]
    public let popoverFilters: [FeedFilter]      // 9 ShareSource cases
    public let selected: Binding<Set<FeedFilter>>

    public init(...) { ... }
    public var body: some View { ... }
}
```

**Visual anatomy:**
- HStack(spacing: LeafSpace.xs) {
    - ForEach visibleFilters { LeafPill(...) }
    - LeafPill(label: "More…", trailing: chevron-down) — popover trigger
- }
- Popover content: VStack of LeafToggle per ShareSource (9 rows).

**Selection logic:**
- `.all` is mutually exclusive with all others (selecting `.all` clears others; selecting other deselects `.all`).
- Other filters multi-select; union applied as feed WHERE clause via SQL.

#### LeafLinkedEventCard (Layouts/)

Rich embedded card showing PR / Issue / Slack message metadata.

**Public API:**

```swift
public struct LeafLinkedEventCard: View {
    public let metadata: AttachmentMetadata?     // nil = loading
    public let externalRef: String               // fallback display if metadata nil
    public let provider: AttachmentProvider      // .github, .linear, .slack
    public let onTap: () -> Void                 // opens URL in browser

    public init(...) { ... }
    public var body: some View { ... }

    public static var compact: SomeStyle { ... }
    public static var full: SomeStyle { ... }
}

public enum AttachmentProvider { case github, linear, slack }
public struct AttachmentMetadata {
    public let title: String
    public let statusLabel: String?              // PR: "open/closed/merged"; Linear: state name
    public let statusColorKey: StatusColorKey    // .open, .closed, .merged, .inProgress, etc.
    public let authorDisplayName: String
    public let createdAtMs: Int64
    public let externalURL: URL
}
```

**Visual anatomy (full):**
- LeafCard.raised + small content padding
- HStack: provider icon (`logo.github`/`logo.linear`/`logo.slack` from `LeafIcons`), VStack(alignment: .leading) {
    - Text(metadata.title).font(LeafType.bodyEmphasis).lineLimit(2)
    - HStack { LeafStatusPill(label: statusLabel, color: statusColorKey), Text("• \(authorDisplayName) • \(timestamp)").font(LeafType.caption) }
- }
- onTap: `NSWorkspace.shared.open(metadata.externalURL)`

**Visual anatomy (compact):**
- HStack: provider icon (small) + Text("#channel-name") or "LEA-123" (LeafType.caption) + chevron.right.small.
- Used in DM crossPostBadge inline row.

### 6.2 Token files (Theme/Tokens/Components/)

New `*Tokens.swift` per atom — spacing, sizing, colors derived from base tokens. Five new token files mirroring atom files.

### 6.3 Preview files (Leaf/Views/Tokens/Components/)

Five new `*Preview.swift` in `Components/`. Sections list (`Leaf/Views/Tokens/Sections/{MoleculesSection.swift, OrganismsSection.swift}` per existing organization) extended with new previews. Discoverable via `⌘⌥T` TokensPreview screen.

### 6.4 Empty states (3 explicit)

Per OQ-S7-7 resolution:

**State 1 — fresh workspace, no members yet.**
- Icon: `person.2.badge.plus` (large, accent color)
- Title: "It's quiet here"
- Body: "Invite teammates to start sharing work."
- Primary CTA: `LeafButton.primary "+ Invite teammate"` → opens `GenerateInviteSheet`
- Secondary CTA: link "or send yourself a test handoff" → opens `SendDirectMessageSheet` pre-filled with self as recipient

**State 2 — members joined, no activity yet.**
- Icon: `bubble.left.and.bubble.right` (large, accent color)
- Title: pluralized — `members == 1` → "1 teammate here"; else "<N> teammates here"
- Body: "Activity will appear as your team shares work."
- Primary CTA: `LeafButton.primary "+ Send first message"`
- Secondary link: "Share Controls: <X of 9> sources enabled" → opens Settings → Share Controls

**State 3 — filters too restrictive.**
- Icon: `line.3.horizontal.decrease.circle` (medium, tertiary)
- Title: "No matches"
- Body: "Try clearing filters or selecting different sources."
- Primary CTA: `LeafButton.secondary "Clear filters"` → resets `FeedFilterStore.clearAll()`
- Secondary text: "<N> items total in this workspace" (informational)

Used uniformly via existing `LeafEmptyState` atom.

### 6.5 Sticky Send button

Top-right of `LeafToolbar` inside TeamView. `LeafButton.primary` with `square.and.pencil` icon + label "Send". Click → `sendSheetPresented = true`. Keyboard shortcut `.keyboardShortcut("n", modifiers: .command)` (only active when TeamView is current section).

Sheet remains S6 `SendDirectMessageSheet` — closure injection preserved per B3.

---

## §7 Mac-side wire layer

### 7.1 TeamFeedReader

**Files (split per §4.2 convention):**
- App-target wrapper: `Leaf/Models/TeamFeedReader.swift` (~120 LOC) — @MainActor @Observable reader exposing state + invoking query service.
- LeafCore query service: `Packages/LeafCore/Sources/LeafCore/Team/TeamFeedQueryService.swift` (~130 LOC) — actor running off-main GRDB SQL + grouping pure function.

**API:**

```swift
@MainActor @Observable
public final class TeamFeedReader {
    public private(set) var state: State = .loading

    public enum State {
        case loading
        case loaded(items: [FeedItem], hasMore: Bool)
        case error(String)
    }

    public enum FeedItem: Identifiable {
        case directMessage(DirectMessageMirrorRow)
        case teamEvent(TeamEventMirrorRow)
        case grouped(kind: String, sender: TeamMember, count: Int,
                     spanStartMs: Int64, spanEndMs: Int64, items: [TeamEventMirrorRow])

        public var id: String { ... }     // unique across DMs + events
        public var timestamp: Int64 { ... }
    }

    public init(database: LeafDatabase, attachmentResolver: AttachmentMetadataResolver) { ... }

    public func loadInitial(workspaceID: String, filters: Set<FeedFilter>, limit: Int = 50) async
    public func loadOlder(workspaceID: String, filters: Set<FeedFilter>, before: Int64, limit: Int = 50) async
    public func refresh(workspaceID: String, filters: Set<FeedFilter>) async  // post-Realtime push trigger
    public func applyGrouping(_ items: [FeedItem]) -> [FeedItem]  // 5+/15m threshold
}

// Nested actor for off-main SQL — implements heavy queries
actor TeamFeedQueryService {
    init(database: LeafDatabase) { ... }
    func fetch(workspaceID: String, filters: Set<FeedFilter>, limit: Int, before: Int64?) async throws -> [TeamFeedReader.FeedItem]
}
```

**Query (SQL):**

```sql
-- Combined union query, parameterized per filter set
WITH combined AS (
    SELECT 'dm' AS source, message_id AS id, sender_pubkey_hex, kind, body,
           sent_at_ms AS ts, server_created_at_ms AS srv_ts,
           direction, recipient_pubkey_hex, read_at_ms, done_at_ms, attachment_kind, attachment_external_ref
    FROM messages_mirror
    WHERE workspace_id = :wid
      AND (:include_dms = 1)  -- bool from filters
      AND (NOT :open_tasks_only OR (kind='task' AND done_at_ms IS NULL AND recipient_pubkey_hex = :me))
    UNION ALL
    SELECT 'evt' AS source, event_id AS id, sender_pubkey_hex, kind, NULL AS body,
           event_ts_ms AS ts, server_created_at_ms AS srv_ts,
           NULL AS direction, NULL AS recipient_pubkey_hex, NULL AS read_at_ms, NULL AS done_at_ms,
           NULL AS attachment_kind, NULL AS attachment_external_ref
    FROM team_events_mirror
    WHERE workspace_id = :wid
      AND source_kind IN (:source_kinds_csv)
)
SELECT * FROM combined
WHERE (:before_ms IS NULL OR srv_ts < :before_ms)
ORDER BY srv_ts DESC
LIMIT :limit
```

GRDB-friendly parameter passing; multiple paths emitted depending on selected filters (avoid SQL injection — value substitution only).

**Grouping algorithm:**

```swift
func applyGrouping(_ items: [FeedItem]) -> [FeedItem] {
    var result: [FeedItem] = []
    var burst: [TeamEventMirrorRow] = []
    let windowMs: Int64 = 15 * 60 * 1000

    func flush() {
        guard !burst.isEmpty else { return }
        if burst.count >= 5 {
            let first = burst.last!     // oldest in burst (chronological inverse)
            let last = burst.first!
            result.append(.grouped(
                kind: burst[0].kind,
                sender: resolveMember(burst[0].sender_pubkey_hex),
                count: burst.count,
                spanStartMs: first.event_ts_ms,
                spanEndMs: last.event_ts_ms,
                items: burst.reversed()))
        } else {
            result.append(contentsOf: burst.map { .teamEvent($0) })
        }
        burst = []
    }

    for item in items {
        switch item {
        case .teamEvent(let row):
            if let head = burst.first,
               head.kind == row.kind &&
               head.sender_pubkey_hex == row.sender_pubkey_hex &&
               abs(head.event_ts_ms - row.event_ts_ms) <= windowMs {
                burst.append(row)
            } else {
                flush()
                burst = [row]
            }
        case .directMessage(let row):
            flush()
            result.append(.directMessage(row))
        case .grouped:
            // Shouldn't reach here from raw query, but defensively pass through
            flush()
            result.append(item)
        }
    }
    flush()
    return result
}
```

### 7.2 CrossPostLogReader

**File:** `Leaf/Models/CrossPostLogReader.swift` (~150 LOC) — app-target reader following S4 `DirectMessageInboxReader` precedent.

**API:**

```swift
@MainActor @Observable
public final class CrossPostLogReader {
    public private(set) var state: State = .idle

    public enum State {
        case idle
        case loading
        case loaded(byMessageID: [String: [CrossPostLogRow]])
        case error(String)
    }

    public init(supabaseClient: SupabaseClient) { ... }

    public func loadForMessages(_ messageIDs: [String]) async
    public func crossPosts(for messageID: String) -> [CrossPostLogRow]
    public func absorbRealtimePush(_ row: CrossPostLogRow)  // called by LeafRealtimeService
}

public struct CrossPostLogRow: Codable, Hashable, Sendable {
    public let messageID: String
    public let platform: String           // "slack" | "linear"
    public let externalRef: String        // e.g., "#leaf-architecture" or "LEA-123"
    public let externalURL: URL
    public let postedAtMs: Int64
    public let errorText: String?         // nil = success
}
```

**Backend:** `SupabaseClient.fetchCrossPostLog(messageIDs: [String]) async throws -> [CrossPostLogRow]`. New `SupabaseEndpoint.crossPostLogByMessageIDs` endpoint. RLS-gated (sender OR recipient via JOIN, per S6 spec §5.1).

### 7.3 AttachmentMetadataResolver

**File:** `Packages/LeafCore/Sources/LeafCore/Team/AttachmentMetadataResolver.swift` (~200 LOC).

**API:**

```swift
public actor AttachmentMetadataResolver {
    public init(database: LeafDatabase, collectorsRegistry: CollectorsRegistry) { ... }

    public func resolve(provider: AttachmentProvider, externalRef: String) async -> AttachmentMetadata?
}
```

**Resolution flow:**
1. Cache lookup (in-actor `[CacheKey: (AttachmentMetadata, Date)]` map keyed by `(provider, externalRef)`; TTL 5min).
2. Local `events` table lookup using SQLite JSON1 extension `json_extract`:
   - `.github` PR: `SELECT payload_json FROM events WHERE event_kind = 'github_pr_opened' AND json_extract(payload_json, '$.external_ref') = ? ORDER BY ts_ms DESC LIMIT 1`. (Similar for other relevant PR-flavor kinds.)
   - `.linear` issue: `WHERE event_kind LIKE 'linear_%' AND json_extract(payload_json, '$.identifier') = ?` (Linear stores `identifier` like "LEA-123").
   - `.slack` message: `WHERE event_kind LIKE 'slack_%' AND json_extract(payload_json, '$.channel_id') = ? AND json_extract(payload_json, '$.ts') = ?`.
   - Performance: query plan uses existing `idx_events_kind_ts` (M011). JSON1 extraction on filtered subset (~thousands of rows post-filter, not millions) is fast enough for feed-render hot path. If profiling shows latency, add expression index in v1.1: `CREATE INDEX idx_events_external_ref ON events(event_kind, json_extract(payload_json, '$.external_ref'))`.
3. Miss → collector fetch fallback:
   - `.github` → existing `GitHubAPIProvider.fetchPullRequest(repoFullName:, number:)` — already implemented per Phase 4.2 substrate.
   - `.linear` → existing `LinearAPIProvider.fetchIssueByIdentifier(...)` or new helper if not present.
   - `.slack` → existing `SlackAPIProvider.fetchMessage(channelID:, ts:)` or new helper.
   - Each provider call gated by valid OAuth scope; on auth-expired → returns nil; resolver caches nil-result for 60s to avoid retry storm; UI shows "Couldn't load" placeholder.
4. Store result in cache; resolver returns; host UI re-renders via @Observable trigger (resolver itself is not @Observable — caller observes via Task .result and triggers @State refresh on host view).

**Privacy:** Resolver lookups against own collectors only — never third-party network call originating from feed render (latency + auth chains). If collector fetch fails → return nil → card shows placeholder with retry-on-tap.

### 7.4 LeafRealtimeService

**Files:**
- App-target wrapper: `Leaf/Models/LeafRealtimeService.swift` (~150 LOC) — @MainActor @Observable connection state surface + dispatch into existing readers.
- LeafCore driver: `Packages/LeafCore/Sources/LeafCore/Network/RealtimeWebSocketDriver.swift` (~300 LOC) — pure actor wrapping `URLSessionWebSocketTask` + Phoenix protocol + reconnect state machine.

**API (app target wrapper):**

```swift
@MainActor
@Observable
final class LeafRealtimeService {
    private(set) var state: ConnectionState = .disconnected
    private(set) var currentWorkspaceID: String?

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case reconnecting(attempt: Int, nextRetryMs: Int64)
        case suspended  // scenePhase != .active
    }

    init(
        supabase: SupabaseClient,
        activeWorkspaceStore: ActiveWorkspaceStore,
        directMessageInboxReader: DirectMessageInboxReader,
        teamEventMirrorReader: TeamEventMirrorReader,
        crossPostLogReader: CrossPostLogReader
    ) { ... }

    /// Idempotent: if called with same wid, no-op; if called with different wid,
    /// internally sends phx_leave for old topic + phx_join for new (channel
    /// switch on persistent WS connection).
    func subscribe(workspaceID: String) async

    /// Sends phx_leave for current channel; keeps WS connection open.
    func unsubscribe() async

    /// Closes WS gracefully; cancels reconnect timers; transitions to .suspended.
    func suspend() async

    /// Re-opens WS using last-known activeWorkspaceID (if any).
    func resume() async
}
```

LeafCore driver (`RealtimeWebSocketDriver`) is pure actor — exposed callbacks via async stream `AsyncStream<RealtimeEvent>` that the app-target wrapper consumes and dispatches to readers.

**Protocol:** Phoenix Channels over WebSocket (full message format in §8.1).

- WS URL: `wss://<project>.supabase.co/realtime/v1/websocket?apikey=<anon>&vsn=1.0.0`
- Single channel per active workspace: `realtime:leaf-workspace-<wid>`. `phx_join` payload includes 3 `postgres_changes` subscriptions (team_events INSERT + direct_messages INSERT + direct_messages UPDATE).
- Auth: send `access_token` in join payload (JWT from `SupabaseClient.session.accessToken`); rejoin on token refresh via tokenRefresh callback.
- Cross_post_log is **NOT** subscribed (no workspace_id column; polling-only via `CrossPostLogReader.loadForMessages` per §8.1 + §7.2).
- Incoming Phoenix message dispatch on `payload.table` (see §8.4).

**Reconnect:**
- Initial connect failure → log + retry 1s.
- Disconnect during session → state `.reconnecting(attempt: 1, nextRetryMs: now + 1000)`.
- Exponential backoff: 1s, 2s, 4s, 8s, 16s, then steady 16s.
- Reset attempt counter on successful reconnect.

**Suspend/resume:**
- `scenePhase != .active` → `suspend()` → close WS gracefully, cancel reconnect timer; state `.suspended`.
- `scenePhase == .active` → `resume()` → trigger fresh connect with current activeWorkspaceID.

**Fallback:** 30s polling tick in `DirectMessageInboxReader` + `TeamEventMirrorReader` continues to fire independently. Cursor-based catch-up handles any missed events when WS not connected. Idempotent UPSERT on mirror tables ensures no duplication when both WS and polling deliver same row.

**Privacy invariants:**
- Encrypted payload arrives via WS → decryption uses local keystore teamKey (never leaves device).
- RLS on Supabase ensures user only receives rows from workspaces they're members of.
- WS auth via short-lived JWT; no long-lived secret exposed.

### 7.5 DirectMessageInboxReader extensions

Existing reader (per `Leaf/Models/DirectMessageInboxReader.swift`): `@MainActor @Observable final class` with `tick() async` (no args — reads `activeWorkspaceStore` internally) + `unreadCount: Int` (per-active-workspace). Adds:

```swift
@MainActor @Observable
final class DirectMessageInboxReader {
    // existing: recentMessages, unreadCount, lastTickError, cachedPubkeyHex, etc.
    private(set) var unreadCountByWorkspace: [String: Int] = [:]   // NEW — per-workspace map

    // Existing tick() extended (signature unchanged):
    func tick() async {
        // ... existing tick logic ...
        await refreshUnreadCounts()
    }

    // NEW — absorbs Realtime INSERT/UPDATE push from LeafRealtimeService dispatch
    func absorbRealtimePush(_ row: DirectMessageRow) async {
        let svc: DirectMessageInboxService
        do { svc = try ensureService() } catch { return }
        await svc.absorbRealtimePush(row)   // service-level UPSERT with C2/C3 guards
        if row.workspace_id == activeWorkspaceStore.activeWorkspaceID {
            refreshLocalState(workspaceID: row.workspace_id)
        }
        await refreshUnreadCounts()
    }

    // NEW — queries across all workspaces (single SQL, no per-workspace key access needed)
    func refreshUnreadCounts() async {
        guard let database = try? ensureDatabase() else { return }
        let counts: [String: Int] = (try? database.read { db -> [String: Int] in
            let rows = try Row.fetchAll(db, sql: """
                SELECT workspace_id, COUNT(*) AS cnt
                FROM messages_mirror
                WHERE direction = 'inbound' AND read_at_ms IS NULL
                GROUP BY workspace_id
            """)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["workspace_id"], $0["cnt"]) })
        }) ?? [:]
        await MainActor.run { unreadCountByWorkspace = counts }
    }
}
```

Trigger paths:
- Every `tick()` (existing 30s foreground loop in OrganizationView → relocated to TeamView `.task(id:)`)
- `absorbRealtimePush` after Realtime UPSERT
- After mark-read action (existing `markRead`/`markDone` flows extended to invoke `refreshUnreadCounts()` post-PATCH)

`TeamEventMirrorReader` mirror service similarly extended with `absorbRealtimePush(_ row: TeamEventRow)` for INSERT events on `team_events` table.

### 7.6 WorkspaceService extensions

`WorkspaceService` is `struct Sendable` with synchronous methods (per `Packages/LeafCore/Sources/LeafCore/Team/WorkspaceService.swift:17`). S7 keeps that convention: new sync methods on the struct for local DB ops; orchestration (server PATCH + local UPDATE) lives in `WorkspaceReader` (Leaf/Models async layer).

```swift
public struct WorkspaceService: Sendable {
    // existing: createWorkspace(displayName:), readWorkspace(id:), listWorkspaces(includeLeft:),
    //          markLeft(workspaceID:at:), rejoin(workspaceID:)

    // NEW — local-only sync ops (server PATCH orchestrated separately by WorkspaceReader)
    public func updateName(workspaceID: String, newName: String) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { throw LeafError.invalidPayload }
        try database.updateWorkspaceName(workspaceID: workspaceID, name: trimmed)
    }

    /// Soft-delete local copy of workspace + cascade DELETE workspace-scoped rows
    /// + remove keystore directory. Server PATCH already done via SupabaseClient
    /// before this call (per orchestration in WorkspaceReader.delete).
    public func softDelete(workspaceID: String, at: Date) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM messages_mirror WHERE workspace_id = ?",
                          arguments: [workspaceID])
            try db.execute(sql: "DELETE FROM team_events_mirror WHERE workspace_id = ?",
                          arguments: [workspaceID])
            try db.execute(sql: "DELETE FROM share_rules WHERE workspace_id = ?",
                          arguments: [workspaceID])
            try db.execute(sql: "DELETE FROM pending_invites WHERE workspace_id = ?",
                          arguments: [workspaceID])
            try db.execute(sql: "DELETE FROM team_event_broadcast_offsets WHERE workspace_id = ?",
                          arguments: [workspaceID])
            try db.execute(sql: "UPDATE workspaces SET deleted_at_ms = ? WHERE id = ?",
                          arguments: [Int64(at.timeIntervalSince1970 * 1000), workspaceID])
        }
        // Per-workspace keystore subdirectory removal (S2 layout)
        let keystoreDir = keystoreRoot
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent(workspaceID, isDirectory: true)
        try? FileManager.default.removeItem(at: keystoreDir)
    }
}
```

**SupabaseClient (actor) additions:**

```swift
public actor SupabaseClient {
    // existing: signInAnonymously, registerPubkey, resolveInvite, probeInvite,
    //           postInvite, insertWorkspaceMember, sendDirectMessage, ...

    // NEW
    public func patchWorkspaceName(id: String, name: String) async throws {
        // PATCH /rest/v1/workspaces?id=eq.<id>
        // Body: {"name": "<name>"}
        // RLS gates: only creator can UPDATE (per M025 policy)
    }
    public func softDeleteWorkspace(id: String) async throws {
        // PATCH /rest/v1/workspaces?id=eq.<id>
        // Body: {"deleted_at_ms": now()}
        // RLS gates: only creator (per M025 policy workspaces_delete_creator)
    }
    public func fetchCrossPostLog(messageIDs: [String]) async throws -> [CrossPostLogRow] {
        // GET /rest/v1/cross_post_log?message_id=in.(<comma-joined-IDs>)
        // RLS gates: sender OR recipient via JOIN (per S6 baseline)
    }
}
```

**Server-side cleanup (S8 carry-over):** Supabase rows (`team_events`, `direct_messages`, `cross_post_log`, `invites`) remain until natural expiry per S5 retention policy (30d via `expires_at` for team_events; forever for direct_messages). Cron job (extending S4 `task_reminders` pattern) in S8 will nuke rows from soft-deleted workspaces (`workspaces.deleted_at_ms IS NOT NULL AND deleted_at_ms < now() - 30d`). For S7 MVP: client deletes local copies + workspace soft-marked; server-side rows auto-expire. Other members of deleted workspace continue receiving their existing rows until expiry — no forced sync-on-delete (acceptable for MVP; cleanup cron deferred to S8).
```

### 7.7 WorkspaceReader extensions (Leaf/Models)

Existing `WorkspaceReader` (per `Leaf/Models/WorkspaceReader.swift`) is `@MainActor @Observable final class` with sync `refresh()` method. S7 adds three async methods that orchestrate Supabase + WorkspaceService + ActiveWorkspaceStore:

```swift
@MainActor
@Observable
final class WorkspaceReader {
    // existing: state, refresh()

    // NEW — closes S2 NIT-3 carry-over
    func leaveActiveWorkspace() async {
        guard case .loaded(let active, _, _) = state else { return }
        do {
            try workspaceService.markLeft(workspaceID: active.id, at: Date())
            let remaining = try workspaceService.listWorkspaces(includeLeft: false)
                .filter { $0.id != active.id }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            activeWorkspaceStore.setActive(remaining.first?.id)
            refresh()
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    // NEW — rename via Supabase PATCH then local UPDATE
    func rename(workspaceID: String, newName: String) async {
        do {
            try await supabase.patchWorkspaceName(id: workspaceID, name: newName)
            try workspaceService.updateName(workspaceID: workspaceID, newName: newName)
            refresh()
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    // NEW — admin-only delete via Supabase soft-delete then local cascade
    func delete(workspaceID: String) async {
        do {
            try await supabase.softDeleteWorkspace(id: workspaceID)
            try workspaceService.softDelete(workspaceID: workspaceID, at: Date())
            if activeWorkspaceStore.activeWorkspaceID == workspaceID {
                let remaining = try workspaceService.listWorkspaces(includeLeft: false)
                    .filter { $0.id != workspaceID }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                activeWorkspaceStore.setActive(remaining.first?.id)
            }
            refresh()
        } catch {
            state = .error(error.localizedDescription)
        }
    }
}
```

Failure semantics:
- `leaveActiveWorkspace` → on success, state transitions to `.loaded(newActive)` or `.empty` (if no remaining); on Supabase / DB error → `.error`.
- `rename` → if Supabase PATCH succeeds but local UPDATE fails → inconsistent state until next refresh tick reads server-of-truth (acceptable; idempotent retry on next manual edit).
- `delete` → if Supabase PATCH succeeds but local cascade fails → user sees error banner; can retry; idempotent (UPDATE workspaces SET deleted_at_ms only changes nil → ts; cascade DELETEs only delete rows that exist).

---

## §8 Realtime layer

Comprehensive impl detail in §7.4 + below.

### 8.1 Phoenix protocol primer

Supabase Realtime is built on Phoenix Channels over WebSocket. Modern API (post-2023) uses **arbitrary channel topic names** + `postgres_changes` config in the join payload. We multiplex multiple CDC subscriptions onto a single Phoenix channel per active workspace.

**Connection:**
- WS URL: `wss://<project>.supabase.co/realtime/v1/websocket?apikey=<anon>&vsn=1.0.0`
- After WS open → send `phx_join` for the workspace topic:

```json
{
  "topic": "realtime:leaf-workspace-<wid>",
  "event": "phx_join",
  "payload": {
    "config": {
      "broadcast": {"self": false},
      "presence": {"key": ""},
      "postgres_changes": [
        {"event": "INSERT", "schema": "public", "table": "team_events", "filter": "workspace_id=eq.<wid>"},
        {"event": "INSERT", "schema": "public", "table": "direct_messages", "filter": "workspace_id=eq.<wid>"},
        {"event": "UPDATE", "schema": "public", "table": "direct_messages", "filter": "workspace_id=eq.<wid>"}
      ]
    },
    "access_token": "<JWT from SupabaseClient.session.accessToken>"
  },
  "ref": "1"
}
```

Server reply (`phx_reply` with `status: "ok"`) — confirms channel join + RLS permits subscriptions.

**Incoming CDC events:**

```json
{
  "topic": "realtime:leaf-workspace-<wid>",
  "event": "postgres_changes",
  "payload": {
    "type": "INSERT",
    "record": { /* row matching column shape */ },
    "schema": "public",
    "table": "team_events",
    "commit_timestamp": "2026-05-16T12:00:00Z"
  }
}
```

Single channel delivers events across all 3 subscriptions; dispatch on `payload.table`.

**Heartbeat:** every 30s send `{"topic":"phoenix","event":"heartbeat","payload":{},"ref":"hb-N"}`. Server replies with `phx_reply` ack. 3 consecutive missing heartbeats → driver assumes disconnect + initiates reconnect.

**Cross_post_log — no Realtime.** Per §7.2: `cross_post_log` lacks `workspace_id` column (it has `message_id` FK only). Realtime `postgres_changes` filter doesn't support JOINs. S7 fetches cross-post status **polling-only** via `CrossPostLogReader.loadForMessages(messageIDs:)` called whenever feed page loads or new DM arrives via Realtime push. Acceptable latency: cross-post badges appear within next feed refresh after DM lands (~1-2s in practice).

### 8.2 Connection lifecycle

```
disconnected → connect() → connecting
connecting → onOpen → connected → join channels → channelJoined
connected → onMessage → dispatch INSERT events
connected → onClose → reconnecting(attempt: 1)
reconnecting → wait backoff → connect() → connecting
suspended (scenePhase) → close + drop reconnect timers → stay until resume
```

### 8.3 Workspace switching

When `activeWorkspaceID` changes:
1. Unsubscribe from current topics (`phx_leave`).
2. Subscribe to new topics with new `wid` filter.
3. No need to disconnect WS — Phoenix multiplexes channels on single connection.

If only one WS connection (one user, one app), single channel per (table, wid) suffices. Future multi-workspace fan-out (UI showing aggregate badges from inactive workspaces) — out of S7 scope.

### 8.4 Message dispatch

Incoming `postgres_changes` event → switch on `(payload.table, payload.type)`:

- `(team_events, INSERT)` → decode `record` → invoke `teamEventMirrorReader.absorbRealtimePush(row:)` → UPSERT mirror via existing `TeamEventMirrorService` plaintext-trust gates (C2/C3 from S5 fix-bundle).
- `(direct_messages, INSERT)` → decode → `directMessageInboxReader.absorbRealtimePush(row:)` → UPSERT mirror; if recipient_pubkey = me, this is inbound — APNs reconciliation idempotent (Realtime arrives ahead of APNs typically; both paths converge on same UPSERT).
- `(direct_messages, UPDATE)` → decode → same `absorbRealtimePush(row:)` — mirror UPSERT preserves `read_at_ms` from latest server state → outbound DM card re-renders with «Read 2m ago» receipt (OQ-14 enhancement).

After any DM push → trigger `crossPostLogReader.loadForMessages([row.message_id])` to populate badge cache (cross_post_log row arrives 1-2s after DM INSERT once Edge Function completes; subsequent fetch picks it up).

All `absorbRealtimePush` methods on readers are new `@MainActor` methods added in §7.5 — they wrap underlying service UPSERT calls.

### 8.5 Decryption + trust gates

Same as S5 mirror service: row arrives → header peek `[ver|keyID]` → keystore lookup → AES-GCM decrypt → plaintext sanity gates (C2/C3 from S5 fix-bundle: senderPubkey claim must match server-attested column; workspaceID must match polling workspaceID). On any mismatch: log + skip + don't UPSERT.

For DMs: additional gate — `recipient_pubkey_hex` must equal local identity pubkey for inbound; for outbound, `sender_pubkey_hex` must equal local identity pubkey. (Defence against RLS-bypass scenarios; primary RLS already filters.)

### 8.6 Privacy

- WS authenticated via JWT (short-lived, refreshable). No long-lived secret in WS protocol.
- All payloads encrypted under workspace teamKey. WS server (Supabase) sees only ciphertexts.
- WS metadata (topic names, timestamps) visible to Supabase — same as REST inbox tick. No new privacy regression.

---

## §9 Settings restructure

### 9.1 WindowSettingsView reorder

Current section order (per Discovery):
1. BackgroundCollection
2. Folders
3. LocalApps
4. SystemObservers
5. ShareControls (S5)
6. Updates
7. Privacy

**S7 new order:**
1. **Workspace (NEW — S7)** — workspace identity + members + invites + leave/delete + new
2. BackgroundCollection
3. Folders
4. LocalApps
5. SystemObservers
6. ShareControls
7. Updates
8. Privacy

Rationale: Workspace is the broadest context (everything is per-workspace); first position aids discovery.

### 9.2 WorkspaceSettingsSection composition

```swift
struct WorkspaceSettingsSection: View {
    @Environment(WorkspaceReader.self) var workspaceReader
    @Environment(ActiveWorkspaceStore.self) var activeWorkspaceStore
    @Environment(PendingInvitesReader.self) var pendingInvitesReader
    // ... other env readers ...

    @State private var renamePresented = false
    @State private var leavePresented = false
    @State private var deletePresented = false
    @State private var generateInvitePresented = false
    @State private var createWorkspacePresented = false

    var body: some View {
        LeafSection(title: "Workspace", description: "Your team workspace identity, members, and invites.") {
            VStack(spacing: LeafSpace.md) {
                workspaceHeaderRow      // name editable + created date + member count
                membersAdminList        // ForEach member rows
                pendingInvitesSection   // ForEach pending invite rows
                actionButtons           // Invite, Leave, Delete, New Workspace
            }
        }
    }
}
```

### 9.3 WorkspaceNameEditor

Inline edit: tap workspace name → transitions to `TextField` bound to `editingName` state → on Submit (Return) → `workspaceService.renameWorkspace(id:, newName:)` → on success, dismiss editing state; on error, show inline `LeafBanner.danger`.

### 9.4 WorkspaceMembersAdminList

Admin determination uses canonical `TeamMember.role == .admin` (set on creator via `WorkspaceService.createWorkspace` line 76, and on first joiner via `InviteAcceptService` — see `Packages/LeafCore/Sources/LeafCore/Team/InviteAcceptService.swift:150,158`):

```swift
let myMember = members.first { $0.pubkeyHex == identity.pubkeyHex }
let viewerIsAdmin = (myMember?.role == .admin)

ForEach members { member in
    WorkspaceMemberAdminRow(
        member: member,
        isMe: member.pubkeyHex == identity.pubkeyHex,
        viewerIsAdmin: viewerIsAdmin,
        onRemove: { /* shows confirmation modal → KeyRotationService.removeMember */ }
    )
}
```

Per row:
- LeafAvatar + display name + joined date (LeafType.caption)
- Role badge: `member.role == .admin` → "Admin" (LeafStatusPill.accent); else "Member" (LeafStatusPill.neutral)
- Action menu (visible if `viewerIsAdmin && !isMe`): `LeafIconButton(icon: "ellipsis")` → context menu:
  - "Remove from workspace" (destructive) → confirmation modal → `KeyRotationService.removeMember(workspaceID:, memberID:)` (S3/Phase 5.3 substrate)

### 9.5 PendingInvitesAdminSection

Relocated from current `Leaf/Views/Window/Team/PendingInvitesSection.swift`. Renders list of `PendingInviteRow` (existing) — name + expiry + status + [Revoke] action. Wired through existing `PendingInvitesReader`.

### 9.6 LeaveWorkspaceConfirmationModal

```swift
struct LeaveWorkspaceConfirmationModal: View {
    let workspaceName: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: LeafSpace.md) {
            Text("Leave \(workspaceName)?").font(LeafType.titleSmall)
            Text("You'll stop receiving messages and updates from this team.\n\nYour local message history will remain available for 30 days, then auto-delete.")
                .font(LeafType.body)
                .foregroundStyle(LeafColor.text.secondary)
            HStack {
                LeafButton.secondary("Cancel", action: onCancel)
                Spacer()
                LeafButton.danger("Leave Workspace", action: onConfirm)
            }
        }
        .padding(LeafSpace.lg)
        .frame(width: 420)
    }
}
```

### 9.7 DeleteWorkspaceConfirmationModal

Similar to Leave but only visible for admins; requires typing workspace name to confirm (extra friction):

```swift
struct DeleteWorkspaceConfirmationModal: View {
    let workspaceName: String
    @State private var typedName = ""
    var canConfirm: Bool { typedName == workspaceName }

    var body: some View {
        VStack(spacing: LeafSpace.md) {
            Text("Delete \(workspaceName)?").font(LeafType.titleSmall)
            Text("This permanently removes the workspace for **all members**. All messages and shared events will be deleted after 30 days.\n\nThis cannot be undone.")
                .font(LeafType.body)
            LeafInput(placeholder: "Type \(workspaceName) to confirm", text: $typedName)
            HStack {
                LeafButton.secondary("Cancel", action: onCancel)
                Spacer()
                LeafButton.danger("Delete Permanently", action: onConfirm)
                    .disabled(!canConfirm)
            }
        }
        .padding(LeafSpace.lg)
        .frame(width: 460)
    }
}
```

### 9.8 WorkspaceCreateSheet

Relocated/copy from `OnboardingView.CreateTeamStepView` (existing). Single field (workspace name) + create button → calls `workspaceService.createWorkspace(displayName:)` (per actual API: `Packages/LeafCore/Sources/LeafCore/Team/WorkspaceService.swift:50`) → on success → `activeWorkspaceStore.setActive(newID)` → dismiss sheet → `WorkspaceReader.refresh()`.

---

## §10 Cross-post badge display (M17 inheritor)

### 10.1 Inline badge rendering

In `LeafMessageCard`, below message body:

```swift
if !crossPosts.isEmpty {
    HStack(spacing: LeafSpace.xs) {
        ForEach(crossPosts) { cp in
            LeafLinkedEventCard.compact(
                provider: provider(for: cp.platform),
                title: cp.externalRef,           // e.g., "#leaf-architecture" or "LEA-123"
                onTap: { NSWorkspace.shared.open(cp.externalURL) }
            )
        }
    }
    .padding(.top, LeafSpace.xs)
}
```

For sender's outbound: same badge (symmetric per OQ-14). Failure case (`cp.errorText != nil`): render warning variant — `LeafIconLabel(icon: "exclamationmark.triangle", text: "Linear post failed")` + tooltip with errorText + tap → retry sheet (M5 carry-over implementation; uses idempotency UUID from S6 §A5).

### 10.2 CrossPostLogReader prefetch

When TeamFeedReader loads a page → for each `.directMessage` item → collect message_ids → `crossPostLogReader.loadForMessages(messageIDs:)` → batch fetch. Subsequent page loads append to cache.

### 10.3 URL composition

`SupabaseClient.fetchCrossPostLog` returns `external_url` directly (Edge Function constructs URL from API response — Slack returns `permalink`; Linear returns issue URL). Mac doesn't compose URLs — trusts server-returned URL (validated as HTTPS-only on read in `CrossPostLogRow.init`).

---

## §11 Carry-overs identified during spec

Tracked for post-S7 / Track 6 / S8:

| ID | Description | Defer to |
|---|---|---|
| M1 | User-defined workspace switcher ordering (drag-reorder + persist) | v1.1 / Track 6 |
| M2 | Workspace switcher pinning (star) for >5 workspaces case | v1.1 |
| M3 | Rich linked event preview cards already in S7 (was originally deferred) — refine animation polish on initial load fetch | post-S7 polish |
| M4 | Member promote/demote — requires `workspace_members.role` column + RLS UPDATE policy | **S8 explicit deliverable** |
| M5 | Cross-post failure retry sheet (M5 ↑ from S6 carry-over) — partially implemented via badge + tap; full retry flow polish | S8 polish |
| M6 | ShareSource popover per-device UserDefaults — cross-device sync if cloud-sync ever added | post-MVP |
| M7 | Feed search (text search across decrypted DMs + event payload titles) | post-MVP |
| M8 | Feed pinning + archival actions | post-MVP |
| M9 | Multi-workspace aggregated unread badge in MenuBar | post-S7 polish |
| M10 | Auto-grouping threshold tuning per source_kind (currently uniform 5+/15m) | v1.1 (data-driven) |
| M11 | DM reactions (👍/👎/🤔) — requires reactions table + WebSocket protocol extension | Track 6 |
| M12 | Workspace icon/avatar customization (currently auto-derived from name) | post-MVP |

---

## §12 Resolved OQs

Per `2026-05-16-track-5-S7-team-ui-alternatives.md` Amendment 2026-05-16:

| OQ | Resolution | Spec section |
|---|---|---|
| OQ-S7-1 | C — full target name + clickable URL | §10 |
| OQ-S7-2 | A — alphabetical sort | §7.6 (WorkspaceReader.listActiveWorkspaces ordering) |
| OQ-S7-3 | A — unread DMs only | §7.5 |
| OQ-S7-4 | A — strict chronological DESC | §7.1 |
| OQ-S7-5 | D refined — 5 visible + 10-toggle popover | §6.1 (LeafFilterChips) + §4.5 |
| OQ-S7-6 | A + ⌘N shortcut | §6.5 |
| OQ-S7-7 | 3 explicit empty states | §6.4 |
| OQ-S7-8 | B — confirmation modal + soft-mark | §9.6 |
| OQ-S7-9 | A — horizontal scroll pill-row | §4.3 view hierarchy |
| OQ-S7-10 | B+C with 1500ms auto-read + keyboard nav | §6.1 (LeafMessageCard) |
| OQ-S7-11 | A — auto-switch + scroll-to + highlight | §8 (state machine through Realtime + WindowState) |
| OQ-S7-12 | 5+/15m + timeline span display | §7.1 (applyGrouping) |
| OQ-S7-13 | A — LazyVStack + 50/page | §6.1 (TeamView ScrollView) + §7.1 (loadOlder) |
| OQ-S7-14 | A + outbound read-receipt via Realtime UPDATE | §6.1 (LeafMessageCard) + §8.4 |
| OQ-S7-15 | Leading checkmark icon + emphasis text + trailing unread badge | §6.1 (LeafWorkspaceSwitcher) |
| OQ-S7-16 | Supabase Realtime + 30s fallback + scenePhase lifecycle | §8 |
| OQ-S7-17 | Rich LeafLinkedEventCard with cached/fetched metadata | §6.1 + §7.3 |
| B1 | TeamView refactor in place; OrganizationView deleted | §4.1 |
| B2 | 2 atoms Layouts/ + 2 Composites/ + LeafLinkedEventCard Layouts/ | §6.1 |
| B3 | S6 closure injection preserved | §6.5 |
| B4 | leaveActiveWorkspace in public LeafCore | §7.7 |
| B5 | Full Settings → Workspace surface | §9 |

---

## §13 Manual smoke (G19) — signed two-Mac gate

**Pre-conditions:** S1+S2+S3+S4+S5+S6+S7 merged to main; Supabase production has all migrations through `20260516120200_workspace_soft_delete_s7.sql` (S3 invite migration `2026051512*` + S5 team_events `20260516120000_team_events_s5.sql` + S6 cross-post `20260516120100_cross_post_s6.sql` + S7 workspace soft-delete `20260516120200_workspace_soft_delete_s7.sql`); on-device SQLCipher migrations M001..M025 applied; alpha.16+ ship; two Macs (Anton's + Dima's).

**G19 golden path:**

1. **Workspace switcher (UC-T5-6)** — Anton creates 2nd workspace "TestClientCorp" → both workspaces visible in sidebar bottom alphabetically (Leaf, TestClientCorp); active = TestClientCorp (newly created, auto-active); switcher row shows filled checkmark + bold name. Click "Leaf" → row's checkmark moves; Team feed re-renders with Leaf workspace context; Settings → Workspace section updates to show Leaf metadata.
2. **Feed render** — Anton sends Handoff DM to Dima from Leaf workspace + 3 git commits push → both visible in Dima's feed within ≤2s (Realtime). Feed order: DESC chronological. Click filter chip "Direct messages" → only DM row visible; click "Activity" → only commit rows. Clear filters → all back.
3. **Realtime read receipt** — Dima opens Leaf workspace, scrolls to Anton's DM, waits 1500ms (auto-read) → Anton's outbound DM card updates within ≤2s to show "Read just now".
4. **Cross-post badge + click** — Anton sends Task DM to Dima with Slack + Linear cross-post (matches G18). Dima's inbound DM card shows two compact badges: `#leaf-architecture` + `LEA-XXX`. Click `#leaf-architecture` → opens Slack to that channel. Click `LEA-XXX` → opens Linear to that issue.
5. **Linked event card** — Anton sends Handoff with attached GitHub PR (`gundemtech/leaf#142`). Dima's inbound DM card shows `LeafLinkedEventCard` with title + status + author + timestamp. Click → opens GitHub PR in browser.
6. **Sticky Send + ⌘N** — Anton scrolls feed deep, [+ Send] button still visible top-right. Press `⌘N` → sheet opens. Send Ping. Sheet auto-dismisses 1.5s on success (S6 pattern preserved).
7. **Settings → Workspace full surface** — Anton opens Settings → Workspace section first. Sees: workspace name "Leaf" (editable on click). Click → text field. Type "Leaf Team". Press Return → workspace renamed locally; Supabase PATCH succeeds. Dima's sidebar updates within ≤30s — propagation via Dima's `WorkspaceReader.refresh()` next polling tick (workspaces table NOT Realtime-subscribed per §8 — rare event, polling sufficient). Members list shows both Anton + Dima with avatars + joined dates. Anton (creator/admin, `member.role == .admin`) has "Admin" LeafStatusPill; Dima has "Member" LeafStatusPill. Anton sees `…` menu on Dima's row → "Remove from workspace" (destructive). [Cancel] → no action. Pending invites section empty (none pending). [+ Invite teammate] → GenerateInviteSheet opens. [Leave Workspace] → confirmation modal "Leave Leaf Team?" → [Cancel] → no action. [Delete Permanently] (admin-only) → confirmation modal with type-name-to-confirm → [Cancel] → no action.
8. **Deeplink** — Anton's Mac inactive (other app). Dima sends Handoff DM in workspace "TestClientCorp" (not active on Anton's Mac). APNs notification arrives "🤝 Dima handed off: ...". Click → Anton's Mac activates → switches active workspace to TestClientCorp → Team tab open → feed scrolled to Dima's new DM card → 2s background pulse highlight (LeafColor.accent.subtle).
9. **Leave workspace** — Anton's Mac, switcher shows 2 workspaces. Right-click "TestClientCorp" → context menu → "Leave Workspace". Confirmation modal → [Leave Workspace]. Workspace soft-marked. Switcher list refreshes; "TestClientCorp" disappears. Active re-resolves to "Leaf Team" (alphabetical first remaining). Feed re-renders Leaf Team context.
10. **Empty states** — Anton creates 3rd workspace "QuietRoom" → switcher updates → click QuietRoom → Team feed empty → State 1 ("It's quiet here") visible with [+ Invite teammate] CTA + secondary "or send yourself a test handoff". After self-invite + send → State 2 ("1 teammate here") or filtered-empty State 3 if filters too restrictive.

**G19 negative paths:**
- Network down (airplane mode) → Realtime WS closes; reconnecting state visible (debug log only, not user-surface for MVP); 30s polling fallback continues; feed updates lag but eventual consistency. Reconnect when network restored.
- Same workspace ID created twice (concurrent admin scenario) → server-side unique constraint rejects second; Mac surfaces "Workspace name taken" inline banner.
- Delete workspace as admin → all members' sidebar updates within 30s (Realtime UPDATE on workspaces.deleted_at_ms); affected members see "<workspace> was deleted" banner.

---

## §14 Test plan

### 14.1 Unit tests (Swift Testing)

**TeamFeedReaderTests** (~25 tests):
- loadInitial empty workspace → empty array
- loadInitial with mix of DMs + events → sorted chronologically
- loadOlder with cursor → next page
- filter `.directMessages` → only DM items
- filter `.openTasks` → only Task DMs with done_at_ms IS NULL AND recipient=me
- filter `.decisions` → only events with source_kind=detectedDecisions
- multi-select filter union
- grouping 4 commits → 4 individual rows
- grouping 5 commits within 15m → 1 grouped row
- grouping 5 commits + 1 PR → grouped + separate rows
- grouping spans timeline correctly (spanStartMs = oldest, spanEndMs = newest)
- grouped item.id stable across re-renders

**CrossPostLogReaderTests** (~12 tests):
- loadForMessages empty → empty map
- loadForMessages with valid IDs → map populated
- crossPosts(for:) returns rows for known ID; empty for unknown
- absorbRealtimePush updates map; subsequent crossPosts(for:) returns updated rows
- error_text rendered → badge variant
- multiple platforms per message → both rendered

**AttachmentMetadataResolverTests** (~15 tests):
- resolve from local events cache hit
- resolve cache miss → collector fetch
- collector fetch failure → returns nil
- cache TTL 5min — expired entry refetches
- concurrent resolves for same ref dedupe (single fetch)
- GitHub PR ref parsing
- Linear issue ref parsing
- Slack message ref parsing

**LeafRealtimeServiceTests** (~20 tests, using mock URLSessionWebSocketTask):
- connect → state .connecting → onOpen → .connected
- phx_join sent on connect
- INSERT event dispatched to correct mirror service
- UPDATE event for direct_messages dispatched
- heartbeat sent every 30s
- onClose → reconnecting state
- reconnect backoff schedule
- suspend → close + cancel timers
- resume → fresh connect
- workspace switch → unsubscribe old + subscribe new

**WorkspaceServiceTests** (extensions, ~10 tests):
- renameWorkspace empty name → throws invalidWorkspaceName
- renameWorkspace > 80 chars → throws
- renameWorkspace success → local row updated
- deleteWorkspace admin success → cascade DELETE local rows + soft-mark + keystore removed
- deleteWorkspace non-admin → server rejects (RLS)

**WorkspaceReaderLeaveTests** (~6 tests):
- leaveActiveWorkspace single-workspace → state .empty
- leaveActiveWorkspace multi-workspace → auto-switch to next alphabetical
- leaveActiveWorkspace error → state .error
- leaveActiveWorkspace race with rename → idempotent

**DirectMessageInboxReaderUnreadCountTests** (~8 tests):
- empty workspace → 0
- 5 unread DMs → 5
- mark one read → 4
- multiple workspaces → independent counts
- Realtime push → updates count

**FeedFilterStoreTests** (~10 tests):
- toggle .all clears others
- toggle other deselects .all
- multi-select union persists to UserDefaults
- switching workspace restores per-workspace selection

### 14.2 Integration tests (XCTest, in LeafCorePrivateTests for moat-touching parts)

**TeamFeedIntegrationTests** (~10 tests):
- end-to-end query with real SQLCipher → returns correct ordering
- pagination with realistic dataset (1000 events) → constant memory + correct pagination cursor

**RealtimePushIntegrationTests** (~6 tests, against local Supabase via `supabase start`):
- INSERT team_events → mirror UPSERT within 2s
- INSERT direct_messages → mirror UPSERT within 2s
- UPDATE direct_messages read_at_ms → outbound mirror UPDATE within 2s
- workspace switch mid-session → channels rotate
- 30s polling reconcile when WS unavailable

### 14.3 View tests (minimal compile + binding)

- LeafMessageCard renders for all kinds + variations (with/without crossPosts, attachment)
- LeafFeedRow renders single + grouped
- LeafWorkspaceSwitcher renders empty / 1 / N workspaces with active indicator
- LeafFilterChips multi-select binding
- LeafLinkedEventCard compact + full + loading variants
- TeamView empty states 1/2/3 render correctly
- WorkspaceSettingsSection renders for admin vs member viewer

### 14.4 Token discipline

`just check-tokens` MUST pass BASE+MIGRATION+RETIRED tiers across:
- All new atom files (Theme/Layouts + Theme/Composites + Tokens/Components)
- TeamView + WorkspaceSettingsSection + all new preview + modal files

### 14.5 Privacy walkbacks (regression fences)

**TeamFeedPayloadLeakageTests** (~12 tests) — sentinel-injection across:
- DM body never leaks into other surfaces
- DM body NEVER appears in TeamFeedReader debug logs (assert log scope)
- Event payload fields NEVER include ADR-010 banned keys (`ai_*`, file_size, secrets patterns)
- AttachmentMetadata never includes raw payload content
- CrossPostLogRow.externalURL must be HTTPS only (validated at init)
- LeafLinkedEventCard never renders attachment metadata raw payload field

**RealtimePayloadLeakageTests** (~6 tests):
- WS message dispatch never logs decrypted payload content
- Failed decrypt → row skipped, no log of partial decrypted bytes
- Heartbeat messages contain no workspace data

### 14.6 pgTAP (server-side, leaf-relay)

`200_workspace_soft_delete_s7.test.sql` — 5+ assertions:
- Migration applies (column + index created)
- Creator soft-delete UPDATE allowed
- Non-creator soft-delete UPDATE rejected (42501)
- SELECT visibility unchanged after soft-delete (clients filter)
- Realtime INSERT on soft-deleted workspace's team_events still permitted (no cascade filter on inserts)

---

## §15 References

- **Track 5 contract:** `2026-05-13-track-5-collaboration-contract.md` — §4 sub-phase decomp, §7 UI surface, §14 multi-workspace
- **S2 substrate:** `2026-05-14-track-5-S2-multiworkspace-substrate.md` — WorkspaceService, TeamKeystore per-workspace, ActiveWorkspaceStore
- **S4 DM primitive:** `2026-05-14-track-5-S4-direct-messages.md` — messages_mirror, DirectMessageInboxReader, APNs handler
- **S5 auto-share:** `2026-05-15-track-5-S5-auto-share.md` — team_events_mirror, TeamEventMirrorReader, ShareRulesReader, denylist, walkback fence
- **S6 cross-post:** `2026-05-16-track-5-S6-cross-post.md` — cross_post_log, SendDirectMessageSheet pattern, idempotency UUID, OAuth scope-bump UX
- **S6 alternatives:** `2026-05-16-track-5-S6-cross-post-alternatives.md` — pattern reference for this S7 alternatives audit
- **S7 alternatives:** `2026-05-16-track-5-S7-team-ui-alternatives.md` — 22-area brainstorm + Amendment for redirect refinements
- **Track 2 D1 tokens:** Track 2 design system (`Leaf/Theme/Tokens/`, `Leaf/Theme/Composites/`, `Leaf/Theme/Layouts/`, `Leaf/Theme/Primitives/`)
- **Whitepaper:** `~/Desktop/Leaf/leaf-docs/docs/team-sharing/` + `privacy-security/` — public-safe framing, ADR-010 invariants
- **ADR-010 invariants:** AI prompt/response NEVER stored; private apps + sensitive paths + large files blocked at source; per-source toggles default OFF for off-the-shelf

---

## §16 Plan handoff

Tactical implementation plan lives at `docs/superpowers/plans/2026-05-16-track-5-S7-team-ui.md` (gitignored — contains moat-sensitive impl details: Phoenix protocol exact frames, decryption byte-handling, grouping window tuning, cache TTL values, exponential backoff schedule).

Plan structure (writing-plans skill output):
- Phase A — Schema migration M025 (local + Supabase + pgTAP test)
- Phase B — New atoms (LeafMessageCard, LeafFeedRow, LeafWorkspaceSwitcher, LeafFilterChips, LeafLinkedEventCard) — TDD per atom
- Phase C — New readers (TeamFeedReader, CrossPostLogReader, AttachmentMetadataResolver) — TDD per reader
- Phase D — LeafRealtimeService — TDD with mock WebSocket
- Phase E — WorkspaceService extensions (rename, delete) + WorkspaceReader.leaveActiveWorkspace
- Phase F — Settings restructure (WorkspaceSettingsSection + sub-views + modals)
- Phase G — TeamView refactor (replace OrganizationView surface) + Sidebar refactor (remove .organization + bottom switcher)
- Phase H — Composition root wiring + lifecycle (scenePhase, .task(id:))
- Phase I — Privacy walkback regression tests (TeamFeedPayloadLeakageTests + RealtimePayloadLeakageTests)
- Phase J — OrganizationView deletion + ShareTemplateButton cleanup if dead-code
- Phase K — Integration tests (RealtimePushIntegrationTests via supabase start)
- Phase L — Token discipline final pass + manual smoke prep

Each phase atomic per commit. Sequential within phase. Stage 6 code review → Stage 7 verification → Stage 8 ship (per `conventions.md` 8-stage workflow).
