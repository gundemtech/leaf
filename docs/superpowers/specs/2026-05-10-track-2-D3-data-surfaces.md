# Track 2 — D3: Data Surfaces

**Date:** 2026-05-10
**Author:** Alex (with Claude)
**Status:** spec for review
**Track:** 2 (UI/UX redesign of Native Leaf macOS app)
**Phase:** D3 of 4 (D1 = Foundation [landed], D2 = Navigation Shell + Home [landed], D3 = Data Surfaces, D4 = Identity & Config)
**Stacked on:** `feature/track-2-D2-navigation-and-home` (D2 не merged в `main`; Track 2 merges коллективно после D4)
**Branch:** `feature/track-2-D3-data-surfaces`

## TL;DR

D2 переписал window shell + Home. **D3 переписывает три data-heavy screen'а** — Activity / Team / Connections — на D1 substrate (3-tier T1/T2/T3 tokens + organisms). Migration approach — Snapshot Replacement: оставшиеся screens (Organization / Settings / Profile / Onboarding / sheets / MenuBar) **не трогаются** (D4 carry-over). Главные архитектурные акценты:

- **Activity** — выкидываем custom `Chip` filter molecule, custom `ProviderIcon` colored backgrounds и decorative category dot. Mode picker (Sessions / Raw events) + provider filter переезжают на `LeafTab`. Rows на `LeafListRow` с neutral leading icon. "Color is a signal" дисциплина — provider identity несёт uppercase typography tag, не purple/green/orange chip background.
- **Team** — членов команды кладём в **adaptive grid** (`LazyVGrid` 240pt min) вместо vertical stack, член = `LeafCard` с `LeafAvatar` + name + `LeafBadge` (accent ADMIN / neutral MEMBER) + mono pubkey-short + overflow `Menu`. Empty state перефразируем gain-framed ("You're solo for now" вместо "No team yet"). "Add member" CTA переезжает в `LeafSection` cta-slot (top-right) — убирает floating bottom button.
- **Connections** — выкидываем native `Form` chrome. Каждый provider = `LeafSection` + `LeafCard` со state-driven rendering. Per-provider state machine (8-9 states) preserved as-is — это OAuth contract, переписывать UX нельзя в D3. **Folds** `Leaf/Views/ConnectionsSettings.swift` (lone Settings-tab artifact) inline в `ConnectionsView.swift`; old file deleted.

**Locale:** English (D2 precedent). UI strings внутри новых views — English; русский только для commit messages / spec / комментариев.

## Vision recap (из D1 § "North Star")

> Leaf — это тихий профессиональный инструмент, который появляется когда нужен и исчезает когда нет.

D3 — место где этот принцип проходит самую жёсткую проверку: data-heavy screens хотят эстетику dashboard'а с trending arrows и decorative chips. D1 принципы D3 буквально применяет:

- **Color is a signal, not a wash** — accent.primary только в active LeafTab indicator + LeafButton primary CTA + LeafBadge.accent для ADMIN. Provider identity (Linear / GitHub / Slack) carries по uppercase typography label, **не** decorative purple/green/orange chip backgrounds.
- **Numbers are quiet** — нет 4-tile metric grids в Activity / Team / Connections (изначально не было — но spec фиксирует discipline). Counts (`× N merged`) folded в primary text inline, не отдельный badge surface.
- **Glass as a quiet material** — `LeafCard.raised` без glass-эффекта на каждом atomic элементе. Glass — на window shell (D2) и sheets (D4); D3 cards — neutral raised surface.
- **Motion is information** — нет animated avatars / wiggle effects / pulsing connection-status dots. `LeafTab` matchedGeometryEffect underline — единственная анимация в D3 (information-bearing: "selection moved here from there").

## Anti-patterns (won't-list для D3)

- ❌ **Decorative provider chip palette** — текущая `ProviderIcon` в `ActivityRow` фыкает purple-Linear / green-Slack / leafAccent-AI цветными backgrounds. Это decorative wash, не signal. **Удаляется**: neutral `LeafColor.surface.inset` background + tertiary-tinted SF Symbol; identity carry'ит `providerLabel` uppercase tag.
- ❌ **Category dot decoration** — `SessionRow` в Phase 4.10.B добавил `Color.leafCategory(category)` (dev=blue / design=pink / etc) маленьким colored circle перед app name. Категории — internal metadata, не user-facing signal. **Удаляется**: identity carries app icon + app name, dot drop.
- ❌ **Floating bottom CTA** — текущий "Add member" button после members list. **Переезжает**: в `LeafSection` cta-slot — top-right, hierarchy-anchored.
- ❌ **Free-text search bar** — Activity получает text search? Нет (YAGNI; нет такого Reader'а; добавило бы privacy-corner — "what events contain word X?" surface). Filter chips (provider) — достаточно.
- ❌ **Animated card hovers** (scale up / glow / shadow change) — out. Default `LeafCard.raised` hover-mute pattern (already in D1 substrate) — это всё.
- ❌ **Stock illustrations / animated mascots** в empty states — D1 §29 carry-over. `LeafEmptyState` SF-Symbol + текст only.
- ❌ **Skeleton shimmer / pulse loading** — D1 §22 carry-over. `.loading` state — простой centered ProgressView.
- ❌ **Per-row separator coloured** — текущий `Divider().opacity(0.3).padding(.leading, 56)` в Activity. **Заменяем**: implicit separation через `LeafColor.surface.raised` hover на rows + neutral `LeafDivider(.soft)` где нужно явное.
- ❌ **Settings-tab artifact reuse** — `Leaf/Views/ConnectionsSettings.swift` живёт outside Window dir, single caller. **Folds** в `Window/Connections/ConnectionsView.swift` — single-screen-per-file simplification. Old file deleted.

## Scope

### В D3

| Файл | Action |
|---|---|
| `Leaf/Views/Window/Activity/ActivityView.swift` | rewrite — header + LeafTab mode picker + LeafTab filter + LeafCard list + 5-state UX |
| `Leaf/Views/Window/Activity/SessionRow.swift` | internal rewrite (interface preserved: `init(session: ActivitySession)`) на LeafListRow + drop category dot |
| `Leaf/Views/Window/Activity/ActivityRow.swift` | internal rewrite (interface preserved: `init(entry: ActivityFeedEntry)`) на LeafListRow + neutral ProviderIcon |
| `Leaf/Views/Window/Team/TeamView.swift` | rewrite — adaptive grid + LeafEmptyState empty + LeafBanner.danger error + LeafSection cta-slot для "Add member" |
| `Leaf/Views/Window/Team/PendingInvitesSection.swift` | internal rewrite (interface preserved: `init()` consumes `@Environment(PendingInvitesReader.self)`) на LeafSection + LeafCard |
| `Leaf/Views/Window/Team/PendingInviteRow.swift` | internal rewrite (interface preserved: `init(invite:)` или whatever existing — verify в plan) на LeafListRow |
| `Leaf/Views/Window/Connections/ConnectionsView.swift` | full rewrite — folds Form-based ConnectionsSettings inline, restructure на LeafSection + LeafCard per provider |
| `Leaf/Views/ConnectionsSettings.swift` | **DELETE** — folds inline в ConnectionsView |
| `scripts/check-tokens.sh` | extend MIGRATION_PATHS — Activity dir + Team file-level + Connections dir |
| `scripts/tests/test-check-tokens.sh` | extend self-test fixtures — D3 MIGRATION paths |

### НЕ в D3 (явно)

- **Sheets** — `GenerateInviteSheet.swift` / `RemoveMemberSheet.swift` (Team), любые OAuth-related sheets если появятся — D4. Old palette остаётся available до D4 cleanup.
- **Sibling screens** — `Organization`, `WindowSettingsView`, `Profile`, `Onboarding`, `MenuBar` dropdown — D4. Live в shell без визуальных изменений.
- **Old palette deletion** (`Leaf/Theme/Colors.swift`, `Theme/Fonts.swift`, `Theme/GlassModifiers.swift`, `Leaf/Views/Window/Shared/GlassCard.swift`) — стабильны до ship D4. D3 их не трогает.
- **`RootView.swift` / `Sidebar.swift` / `Home/`** — D2-migrated, не трогаются в D3 (исключение — нет).
- **`LeafApp.swift`** — `.onOpenURL` / `.scenePhase` clipboard probe / `OpenSettingsCommand` / scenes — preserved.
- **`RemovedFromTeamBanner.swift`** — Phase 5.3.E component preserved as-is.
- **Reader changes / new InsightsSnapshot fields** — D3 — pure UI substrate. Использует existing data из `InsightsReader` / `OrgReader` / `PendingInvitesReader` / `LinearOAuthService` / `GitHubOAuthService` / `SlackOAuthService` без модификации contracts.
- **Team presence / incoming presence rendering** — Phase 5.4 (когда `presence_outgoing` + `presence_history` появятся в pipeline). D3 stays at identity level (members + roles + pubkeys), без presence ring on avatars.
- **Activity free-text search / pagination UI** — out (см. § Anti-patterns).
- **Connections "Last sync N min ago" timestamp** — требует Reader work (последний successful poll timestamp not currently stored). Out. Текущий "Connected `<relative>`" preserved + статичный hint "Polls every 5 min".
- **Share Controls UI scaffolding** — Phase 5.4+. D3 ничего не surface'ит про Share Controls (avoid promising non-existent feature).
- **Provider logo Asset Catalog additions** (linear-mark / github-mark / slack-mark) — out. SF Symbols (per-event-kind mapping в `ActivityRow`) preserved; provider identity carries text label.

### Acceptance criteria

1. `⌘⌥T` Tokens Preview всё ещё открывается и рендерится без regressions (D1 substrate не сломан) — sanity carry-over.
2. **Activity** — header + mode picker (`LeafTab` over `ActivityMode`) + раздел content в обоих modes:
   - Sessions: `LeafCard` wrapping list of `LeafListRow`-rendered SessionRows (app icon leading, app name + context secondary, duration trailing mono).
   - Raw events: `LeafTab` filter (`ActivityFilter` 6 cases) + `LeafCard` wrapping list of `LeafListRow`-rendered ActivityRows (neutral ProviderIcon leading, `[PROVIDER] · primary [×N]` formatted, secondary, relative time trailing mono).
3. **Activity** — все 5 InsightsReader states:
   - `.loading` → centered ProgressView под header.
   - `.notConfigured(msg)` → `LeafEmptyState` centered (icon: `leaf-status-warning`, title: msg).
   - `.empty(msg)` → `LeafEmptyState` centered (icon: `leaf-brand-leaf`, title: "Nothing yet today", description: msg).
   - `.error(msg)` → `LeafBanner.danger` top + retry CTA → `reader.refresh()`. Body content omitted (D2 simpler-recovery pattern carry-over).
   - `.loaded` → full content render.
4. **Team** — adaptive grid layout (`LazyVGrid(columns: [GridItem(.adaptive(minimum: 240))])`); каждый member = `LeafCard.raised` с `LeafAvatar` (initials) + name + `LeafBadge` (accent ADMIN / neutral MEMBER) + mono pubkey-short + overflow `Menu` (hidden для self-row).
5. **Team** — все 5 OrgReader states:
   - `.loading` → centered ProgressView.
   - `.empty` → `LeafEmptyState` (icon: `leaf-nav-team`, gain-framed title "You're solo for now", description, CTA "Open Organization" → `windowState.section = .organization`).
   - `.loaded(_, members)` → header + `LeafSection` (title "Team · N members", cta = `LeafButton.primary("Add member", icon: .system("plus"))`) wrapping member grid + `PendingInvitesSection`.
   - `.removedFromOrg` → `EmptyView()` (RootView preempts).
   - `.error(msg)` → `LeafBanner.danger` top + retry button.
6. **Team — PendingInvitesSection** — D3 substrate rendering: hides if no rows; otherwise `LeafSection(title: "Pending invites · N")` wrapping `LeafCard` with `LeafListRow` per invite. Internal `pollingHint` сохраняется как ambient caption (`LeafType.body.small`, `text.tertiary`).
7. **Connections** — header + 3 provider blocks (Linear / GitHub / Slack), каждый = `LeafSection` (title, description) wrapping `LeafCard.raised` with state-driven content; native `Form` chrome — gone.
8. **Connections per-provider state machine** — все existing states preserved with D1 organism rendering:
   - `.notConnected` → leading `LeafIcon` (asset, lg, text.tertiary) + title "Not connected" + description + `LeafButton.primary("Connect <Provider>")`.
   - `.authorizing / .waitingForCallback / .exchangingToken / .fetchingWorkspace / .fetchingViewer / .requestingDeviceCode` → inline ProgressView + label.
   - `.awaitingAuthorization` (GitHub) — special — userCode (LeafType.mono.large weight=semibold с textSelection enabled) + 2 `LeafButton`s "Open in browser" / "Copy code" + ghost "Cancel" + countdown caption.
   - `.connected(workspaceName, connectedAt)` → `LeafDot.success` + workspace name + relative time caption + `LeafButton(variant: .destructive)` "Disconnect" + static "Polls every 5 min" hint.
   - `.reconnectNeeded` → `LeafIconLabel` (warning tint) + description + `LeafButton.primary("Reconnect <Provider>")`.
   - `.error(msg)` → `LeafBanner.danger` inside the card + "Try again" button.
9. **Connections** — `await service.connect()` flow trigger preserved (browser-based OAuth, NO redesign of auth UX).
10. `just check-tokens` passes для всех D3-scope files; `just check-tokens-self-test` passes (включая новые file-level + dir-level fixtures).
11. 5/5 xcodebuild schemes green (Leaf / LeafAgent / LeafCore / LeafCorePrivate / LeafMCP).
12. 1213 SPM tests baseline preserved (zero new tests — D3 — pure UI substrate, нет logic worth automating; runtime validate через manual smoke).

## Aesthetic anchors

D1 / D2 anchors carry over:

- **Apple-native** через Liquid Glass system materials (sheets carry-over, D3 cards — `LeafCard.raised` neutral).
- **Notion** через generous whitespace, content-first hierarchy, soft palette.
- **Linear** через precision, hover-state quality, monospace для IDs / hex / timestamps.

D3-specific:

- **Activity** — Linear-style precision: monospace duration trailing, mono relative-time trailing, uppercase provider tag inside primary text. List rows scan vertically; LeafTab underline indicator → moves between modes/filters with snappy spring (information-bearing, not decorative).
- **Team** — Notion-style headshot grid: cards stacked in adaptive grid, member identity carries primarily via name + role chip; pubkey hex — secondary surface. Avatar initials в neutral surface.inset background — not branded color.
- **Connections** — Apple-native form-block discipline без `Form` chrome: each provider = LeafSection block with LeafCard inside, identity carried by section title (typography), state by content (button + dot). No section dividers; LeafSpace.xl gap between sections.

## Information Architecture

### Activity

```
ActivityView (ScrollView → VStack)
├─ Header (LeafSpace.xl bottom)
│   "ACTIVITY · TODAY"      ← Text.leafSectionLabel, text.tertiary
│   "<mode-specific copy>"  ← LeafType.body.regular, text.secondary
├─ switch reader.state {
│   case .loading           → ProgressView centered (под header)
│   case .notConfigured     → LeafEmptyState (warning icon)
│   case .empty             → LeafEmptyState (leaf icon)
│   case .error             → LeafBanner.danger (top, with retry CTA)
│   case .loaded(snapshot)  → content(snapshot)
│ }
└─ content(snapshot):
   ├─ LeafTab(selection: $mode, tabs: [.sessions, .rawEvents], label: \.title)
   ├─ if mode == .rawEvents → LeafTab(selection: $filter, tabs: ActivityFilter.allCases, label:)
   │                          // labels include count when > 0: "Linear · 12"
   └─ LeafCard(variant: .raised, padding: .tight) {
        if rows.isEmpty → LeafEmptyState (mode-specific message, no CTA)
        else → VStack(spacing: 0) {
          ForEach(rows) {
            (SessionRow|ActivityRow) … on LeafListRow
            if !last → LeafDivider(.soft).padding(.leading, LeafSpace.4xl)
          }
        }
      }
```

**Key choices:**

- **Header copy describes mode.** Sessions: "Continuous work blocks: app + window/file context." Raw events: "Every event the agent has captured today." Same as current — informational anchor for what this list represents.
- **Mode + filter — both via `LeafTab`.** Unified UX, eliminates custom `Chip`/`FilterBar`. Tabs are 2 (sessions/rawEvents) and 6 (all/local/linear/github/slack/ai); fits within 920pt min window. Filter row appears only in `.rawEvents` mode (Hick's Law — fewer choices when not needed).
- **Filter labels include count:** `LeafTab.label` closure returns `filter.title + (count > 0 ? " · \(count)" : "")` — count text is part of the tab label string. No separate badge/chip — D1 substrate respected (LeafTab is Tab-segments-label-only). User scans counts inline.
- **Single `LeafCard.raised` wraps the whole list**, not card-per-row (anti-pattern: 4-tile dashboard). Internal divider — `LeafDivider(.soft)` with leading inset matching leading-icon column width (`LeafSpace.4xl` ≈ 64pt). Soft visual separation; no horizontal hairline-row blocks.
- **Sessions list bound:** existing 200-row cap from Reader holds. `recentSessions.sorted { $0.start > $1.start }` preserved.
- **Raw events ordering / coalesce preserved:** entries already coalesced + sorted by reader.

### Team

```
TeamView (ScrollView → VStack)
├─ switch reader.state {
│   case .loading           → ProgressView centered
│   case .empty             → LeafEmptyState ("You're solo for now" + Open Organization CTA)
│   case .loaded(_, members) → loadedContent(members)
│   case .removedFromOrg    → EmptyView() (RootView preempts via RemovedFromTeamBanner)
│   case .error(msg)        → LeafBanner.danger (top) + retry
│ }
└─ loadedContent(members):
   ├─ LeafSection(
   │     title: "Team · \(members.count) member\(s)",
   │     cta: { LeafButton.primary("Add member", icon: .system("plus"), action: → showingGenerateSheet = true) }
   │   ) {
   │     LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 360))], spacing: LeafSpace.md) {
   │       ForEach(members) { member in
   │         memberCard(member)
   │       }
   │     }
   │   }
   └─ PendingInvitesSection()       // hides itself when no rows; D3-substrate-rewritten
```

**Member card layout (LeafCard.raised, padding: .regular):**

```
HStack(spacing: LeafSpace.md) {
  LeafAvatar(initials: <first/last>, size: .md)        // 36pt
  VStack(alignment: .leading, spacing: LeafSpace.xxs) {
    HStack(spacing: LeafSpace.xs) {
      Text(member.displayName)                          // LeafType.body.regular, text.primary
      LeafBadge(text: role.uppercase, variant: roleVariant(member.role))
                                                        // accent для ADMIN, neutral для MEMBER
    }
    Text(pubkeyShortHex(member.pubkeyHex))               // LeafType.mono.small, text.tertiary
  }
  Spacer()
  if !isSelf { overflowMenu(member) }
}
```

**Overflow menu**: `Menu { Button("Remove from team…", role: .destructive, action: …) } label: { LeafIcon(systemName: "ellipsis", size: .md, tint: text.tertiary) }`. Self-row hides menu (existing logic preserved: compare `member.pubkeyHex` to `myPubHex` from `IdentityService.ensureLocalIdentity`).

**Empty CTA copy** (gain-framed):

> Title: "You're solo for now"
> Description: "Create an org or accept an invite to start sharing presence with teammates."
> CTA: "Open Organization" → `windowState.section = .organization`

Why gain-framed: avoids "no team" deficit-framing; positions next-step as opportunity (loss-aversion in empty-states heuristic).

**"Add member" CTA placement** — `LeafSection.cta` (top-right) instead of below grid as a bottom-floating button. Makes primary action hierarchy-anchored (visible without scrolling), removes vertical centerpiece weight from grid.

### Connections

```
ConnectionsView (ScrollView → VStack)
├─ Header (LeafSpace.xl bottom)
│   "CONNECTIONS"           ← Text.leafSectionLabel, text.tertiary
│   "Connections"           ← LeafType.title.large, text.primary
│   "Linear, GitHub, Slack — sources of truth Leaf observes on your behalf."
│                           ← LeafType.body.regular, text.secondary
└─ VStack(spacing: LeafSpace.xl) {
     providerSection(.linear, service: linearOAuth)
     providerSection(.github, service: githubOAuth)
     providerSection(.slack,  service: slackOAuth)
   }

providerSection(provider, service):
  LeafSection(
    title: provider.displayName,           // "Linear" / "GitHub" / "Slack"
    description: provider.subtitle         // "Read-only access — issue activity"
  ) {
    LeafCard.raised(padding: .regular) {
      providerStateContent(provider, service.state)
    }
  }
```

**Per-state content** — see acceptance criteria #8 for exhaustive mapping. Patterns:

- **`.notConnected`**: VStack {`LeafIcon(asset: <provider-status-icon>, size: .lg, tint: text.tertiary)` (or skip if no asset) → Title "Not connected" `LeafType.title.small` → description `LeafType.body.small text.secondary` → `LeafButton.primary("Connect <Provider>", action: { Task { await service.connect() } })`}
- **Connecting states** (multiple kinds): `HStack { ProgressView().controlSize(.small); Text(progressLabel) }` — label state-specific.
- **GitHub `.awaitingAuthorization`**: VStack { Text("Enter this code on GitHub") title.small → user code (LeafType.mono.large weight=semibold + textSelection enabled — verify mono.large size = 28pt or use raw token deviation if mono.large doesn't exist; see § Open Q) → `HStack { LeafButton.primary("Open in browser") · LeafButton.secondary("Copy code") · LeafButton.ghost("Cancel") }` → countdown caption (LeafType.body.small text.tertiary, format "Code expires in M:SS") }
- **`.connected(workspace, connectedAt)`**: `HStack { LeafDot(.success, size: .md); VStack { Text(workspaceName) title.small text.primary; Text("\(relativeFormatter.localizedString(connectedAt)) · Polls every 5 min") body.small text.tertiary }; Spacer(); LeafButton(variant: .destructive, "Disconnect") }`
- **`.reconnectNeeded`**: `LeafIconLabel(icon: .asset(LeafIcons.status.warning), title: "Reconnect needed", iconTint: status.warning, titleStyle: title.small)` + description + primary CTA "Reconnect <Provider>".
- **`.error(msg)`**: `LeafBanner(tone: .danger, title: "Couldn't authenticate", description: msg, ctaTitle: "Try again", onCTA: { Task { await service.connect() } })` rendered INSIDE the card (LeafCard's content slot).

**Why one big card per provider, not one big card containing all 3**: each provider has independent state machine + independent CTA. Co-locating их в один card inflates the "what action do I take" cognitive load (Hick's Law); separate sections allow eye to scan one provider state at a time.

**Footer copy ("Data stays on your device, encrypted with the same key as your local activity DB" — current)** — drop. The whole app brand is "data on device"; redundant per-provider footer reads as PR copy. If we want the assurance, surface it once in screen subtitle (header description). Decision: keep header description as is, drop per-provider footer.

## State machine UX

### Activity (5 states, full machine)

| State | Render |
|---|---|
| `.loading` | `ProgressView().controlSize(.small)` + label "Reading today's events…" centered under header. **No animations** (D1 §22). |
| `.notConfigured(msg)` | `LeafEmptyState` centered (icon: `LeafIcons.status.warning`, title: msg, no description). |
| `.empty(msg)` | `LeafEmptyState` centered (icon: `LeafIcons.brand.leaf`, title: "Nothing yet today", description: msg). |
| `.error(msg)` | `LeafBanner(tone: .danger, title: "Couldn't load today's events", description: msg, ctaTitle: "Try again", onCTA: { reader.refresh() })` at top. List body omitted (simpler-recovery pattern carry-over from D2). |
| `.loaded(snapshot, _)` | full mode-picker + filter (rawEvents only) + LeafCard list render per IA above. |

### Team (5 states, full machine)

| State | Render |
|---|---|
| `.loading` | Centered `ProgressView()`. |
| `.empty` | `LeafEmptyState` (icon: `LeafIcons.nav.team`, title: "You're solo for now", description: "Create an org or accept an invite to start sharing presence with teammates.", ctaTitle: "Open Organization", onCTA: `windowState.section = .organization`). |
| `.loaded(_, members)` | Loaded content per IA: `LeafSection` (title + Add member CTA) wrapping member grid + `PendingInvitesSection`. |
| `.removedFromOrg` | `EmptyView()` — RootView preempts via `RemovedFromTeamBanner` full-screen takeover. |
| `.error(msg)` | `LeafBanner(tone: .danger, title: "Couldn't load team", description: msg, ctaTitle: "Try again", onCTA: { reader.refresh() })` at top. |

### Connections (per-provider state machine, 6-9 states each)

No screen-level state machine — Connections has no Reader; each provider is `@Bindable` service with its own `state: ConnectionState` enum. The screen always renders header + 3 provider sections; per-card content switches на service.state. См. § acceptance criteria #8 для exhaustive state-to-render mapping.

## Token discipline guard extension

D2 already established the two-tier scope (BASE + MIGRATION) with file + dir support and old-palette ban на MIGRATION dir. D3 extends only `MIGRATION_PATHS`:

**Added to MIGRATION (D3):**

- `Leaf/Views/Window/Activity/` — dir-level (3 files: ActivityView, SessionRow, ActivityRow — все мигрируют)
- `Leaf/Views/Window/Team/TeamView.swift` — file-level
- `Leaf/Views/Window/Team/PendingInvitesSection.swift` — file-level
- `Leaf/Views/Window/Team/PendingInviteRow.swift` — file-level
- `Leaf/Views/Window/Connections/` — dir-level (1 file: ConnectionsView — после fold/delete)

**NOT added (intentionally out of scope):**

- `Leaf/Views/Window/Team/GenerateInviteSheet.swift` — D4 sheet rewrite
- `Leaf/Views/Window/Team/RemoveMemberSheet.swift` — D4 sheet rewrite

Sheets stay on old palette. Dir-level scope on `Team/` would inadvertently include the sheets; **file-level scope** chosen specifically для Team чтобы exclude sheets cleanly.

**Self-test fixtures (T8):** add 4-6 new cases:

- D3 MIGRATION dir (Activity) — clean fixture passes; raw-padding fail; old-palette fail.
- D3 MIGRATION file-level (Team) — clean fixture passes; old-palette fail для одного файла из listed-files (TeamView), pass для unlisted (sheet path).
- (Reuse env-override mechanism `LEAF_CHECK_TOKENS_EXTRA_FILES` from D2 — no script-level changes needed beyond paths.)

## Out-of-scope для D3 (carry-over)

- **D4** — Organization / WindowSettingsView / Profile / Onboarding / MenuBar dropdown / GenerateInviteSheet / RemoveMemberSheet / AcceptInviteSheet polish. Old palette removal cleanup.
- **Phase 5.4** — Team presence rendering (incoming presence от teammates на avatar status rings + "Last active" caption per member). `presence_outgoing` + `presence_history` пока не surfaced в Reader.
- **Connections "Last sync N min ago"** — требует new Reader work (последний successful poll timestamp not stored).
- **Activity free-text search / pagination** — out (см. § Anti-patterns).
- **Provider logo Asset Catalog additions** (linear-mark / github-mark / slack-mark) — SF Symbols continue to carry per-event-kind identity; provider-name carried by uppercase text label.
- **Share Controls UI** — Phase 5.4+ (fully invisible / app whitelist / per-event-type whitelist).
- **Mode persistence** в Activity (session vs raw events selection across app restarts) — out. Default `.sessions` carry-over (current behaviour).

## Open questions / risks (decided)

Standalone questions raised during brainstorm (no user в loop — каждое resolved with documented tradeoff). All decisions enacted in spec above; this section is the audit trail.

- **OQ-1: Activity timeline grouping (flat vs grouped by day).** Tradeoff: grouped surfaces "Today / Yesterday" anchors (Notion-style block hierarchy); flat is simpler. Reader currently caps at "today only" (`recentActivity` / `recentSessions` уже filtered server-side). Grouping would be artificial — единственный bucket = today. **Decided:** flat reverse-chrono within "TODAY" anchor (header carries the temporal scope label). If Reader later expands to multi-day, group then.

- **OQ-2: Per-row representation in Activity (LeafListRow vs custom row).** LeafListRow's `(leading, trailing)` slots fit exactly: leading = icon, primary = main text, secondary = sub-text, trailing = duration/relative-time. **Caveat:** `primary` is plain `String` — `× N merged` badge can't be a separate UI surface inside primary slot. **Decided:** fold `× N` into primary text inline ("ENG-123 ×3"); LeafBadge interruption avoided. Acceptable simplification.

- **OQ-3: Filter UI primitive (custom Chip vs LeafTab vs LeafPill).** LeafPill (D1 M3) is display-only — no selection state, no tap action. LeafTab (D1 O9) is segmented strip with bound selection. **Decided:** LeafTab for both ActivityMode (2 cases) and ActivityFilter (6 cases). Eliminates need for new D1 substrate component. ActivityFilter conforms to `Identifiable` (id = rawValue) — already done; ActivityMode needs `Identifiable` conformance (id = rawValue).

- **OQ-4: Filter count rendering inside LeafTab.** LeafTab's `label: (Tab) -> String` closure returns single string. **Decided:** format count into label string when > 0 ("Linear · 12") — keeps scanning anchor without forcing substrate change. When count == 0, drop suffix ("Linear").

- **OQ-5: ProviderIcon background colour discipline.** Current `Color.purple.opacity(0.18)` (Linear), `.green.opacity(0.18)` (Slack), `.leafAccent.opacity(0.22)` (AI) — decorative provider chip backgrounds. **Decided:** drop. Replace with `LeafColor.surface.inset` neutral background + `LeafColor.text.tertiary`-tinted SF Symbol. Provider identity carried by uppercase `providerLabel` text in primary line. Rationale: "Color is a signal, not a wash" — accent reserved для needs-attention; provider identity не signal-bearing.

- **OQ-6: Category dot in SessionRow.** Current `Color.leafCategory(category)` (dev/browse/communication/design/other) — small colored circle before app name. **Decided:** drop. Categories — internal metadata, not user-facing signal. App identity carried by real OS app icon (resolved via AppIconResolver) + app name. Less noise. If user later wants scan-by-category, add as filter affordance, not row decoration.

- **OQ-7: Team grid vs list.** Grid scans "headcount snapshot" Linear-style; list — denser metadata per row. MVP team size 1-5, max ~50; window min 920pt. 3-col adaptive at 920pt works (3 cards × ~280pt). **Decided:** `LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 360))], spacing: LeafSpace.md)`. Adaptive: 3-col narrow, 4-col wide (>1200pt). Card layout horizontal-compact (avatar leading, vertical text stack right).

- **OQ-8: Member card layout — vertical-headshot vs horizontal-compact.** Vertical (avatar centered top, text below) evokes team-page aesthetic; horizontal denser, supports more cards on screen. With initials-only avatars (no real headshot images), vertical amplifies synthetic feel. **Decided:** horizontal-compact. If D4 polish surfaces headshot upload, switch then.

- **OQ-9: PendingInvitesSection migration scope.** It's inline content in TeamView — not a sheet (sheets are D4 carry-over). Team dir в MIGRATION → PendingInvitesSection + PendingInviteRow inside. Current files use old palette. **Decided:** D3 migrates both internally on D1 substrate (LeafCard + LeafSection + LeafListRow + LeafBadge + LeafButton). Sheets `GenerateInviteSheet` + `RemoveMemberSheet` explicitly NOT in MIGRATION (file-level scope, not dir-level, для Team; sheets paths excluded).

- **OQ-10: Connections — Form vs LeafSection-blocks.** Native `Form(formStyle: .grouped)` carries macOS chrome. **Decided:** drop Form entirely. Each provider = `LeafSection` + `LeafCard` block. Native chrome → custom design system chrome. Visual consistency с rest of redesigned app.

- **OQ-11: ConnectionsSettings.swift fold.** Currently lives at `Leaf/Views/ConnectionsSettings.swift` (NOT в Window/Connections/) с single caller (ConnectionsView). Phase 4.1 artifact — original "Settings tab" surface, moved later under Window section. **Decided:** D3 folds inline в `Window/Connections/ConnectionsView.swift` and deletes `Leaf/Views/ConnectionsSettings.swift`. Single-screen-per-file simplification.

- **OQ-12: Connections — last-sync timestamp surfacing.** "Polls every 5 min" — does it deserve UI surface beyond static hint? Real "Last sync N min ago" requires Reader work. **Decided:** D3 stays at static "Polls every 5 min" caption inside `.connected` state. Real timestamp = Phase 5.4 / parallel track.

- **OQ-13: Activity LeafCard variant — `.raised` vs `.glass`.** Glass — heavy material для quiet list view; raised — neutral elevated surface. **Decided:** `.raised` (canonical "data list inside card" pattern). Glass reserved для shell + sheets per D1 §"Glass as a quiet material".

- **OQ-14: GitHub user-code typography.** Current uses raw `Font.system(size: 28, weight: .semibold, design: .monospaced)`. D1 substrate `LeafType.mono.regular` = 14pt, `LeafType.mono.small` = 12pt — neither matches 28pt requirement. **Decided:** add new T2 token `LeafType.mono.large` = 28pt semibold (verify в plan — if D1 namespace doesn't have it yet, add as part of D3 plan T7). Alternative: raw `Font.system(size: 28, weight: .semibold, design: .monospaced)` accepted as a token deviation comment-justified — but that violates token guard. Cleaner: add the token. Single new T2 token addition; no T3 scope needed (mono.large used only in awaitingAuthorization). **Update inside plan**: if `LeafType.mono.large` already exists в D1 substrate (Discovery showed only mono.regular + mono.small), add it; else use raw with `// MIGRATION: add LeafType.mono.large` comment + token guard suppression — NOT acceptable. Add the token.

  Verifying: D1 spec § "Typography" lists mono.regular (14) and mono.small (12) only — no mono.large. **Decided:** add `LeafType.mono.large = SF Mono 28 semibold tracking 0` as part of T7 (Connections rewrite) — single line addition в `Leaf/Theme/Tokens/LeafType.swift`. Exception to "D3 doesn't modify D1 substrate" — this is additive (new namespace member), not modification of existing API. Token-discipline аналог D2's `activeThresholdSeconds` extension to `LeafStatusPillTokens` (allowed because additive).

- **OQ-15: Member card overflow Menu — D1 LeafIconButton vs raw SwiftUI Menu primitive.** `LeafIconButton` is button-only (action closure). `Menu` (SwiftUI primitive) opens pop-out with destructive options. They are different control types. **Decided:** keep raw `Menu { Button(...) } label: { LeafIcon(systemName: "ellipsis", size: .md, tint: text.tertiary) }`. Menu primitive не in scope of D1 organism replacement. Label = LeafIcon (substrate organism). Self-row hides `Menu` (existing logic preserved).

- **OQ-16: Team `Add member` CTA — LeafButton.primary in LeafSection cta-slot vs separate row.** `LeafSection.cta` slot pinned top-right в section header. **Decided:** primary CTA в cta-slot. Hierarchy-anchored. Removes floating bottom centerpiece. Если grid очень длинный (50+ members) и юзер заскроллил вниз — CTA вне видимости; mitigated тем что 50+ members уже edge case в MVP.

- **OQ-17: Activity error state — banner top + content omitted, или banner top + stale content below.** D2 chose simpler-recovery (omit content). **Decided:** D3 follows D2 precedent. If usability suffers, add cache-last layer post-D3 — но 1213 baseline test discipline says "no new logic worth automating in D3" — Reader-level cache не in scope.

- **OQ-18: PendingInvitesSection error state.** PendingInvitesReader has 3 states (`.loading / .loaded / .error`). If `.error`, what does the Section render? Options: (a) hide section entirely; (b) inline LeafBanner.danger inside section. **Decided:** (b) — inline LeafBanner.danger. Section visibility tells user "we tried"; banner explains why. Avoid silent failure (auditability).

- **OQ-19: Locale strings.** All new UI labels — English (D2 precedent + product copy already English). Russian — only commits / spec / code comments.

- **OQ-20: Mode picker `.sessions` vs `.rawEvents` default.** Current default `.sessions` (most useful "what was I doing"). **Decided:** preserve. No persistence across restarts (state property = ephemeral). Future track: persist via `@AppStorage`.

- **OQ-21: Filter chip clear / "all" reset gesture.** Current default `.all`; user can click "All" tab to reset. **Decided:** preserve. No separate clear button (LeafTab handles selection naturally).

## Glossary

- **D3-scope files** — files перечисленные в § "Scope > В D3" (10 files: 3 Activity + 3 Team + 1 Connections + 1 Connections-folded-deleted + 2 scripts). После D3 ship — все на D1 substrate (zero old-palette refs); все остальные files unchanged.
- **Snapshot Replacement migration** (D1 § "Migration approach") — D1 substrate ships без переезда existing views; D2/D3/D4 мигрируют свои views in-place. Old palette остаётся available для не-migrated views.
- **MIGRATION scope (token guard)** — D1 + D2 mechanism: paths под more strict guard discipline (BASE checks + old-palette ban). D3 extends with Activity dir + Team file-level + Connections dir.
- **Folding ConnectionsSettings.swift** — moving the Form-based content из `Leaf/Views/ConnectionsSettings.swift` (Phase 4.1 artifact) inline в `Leaf/Views/Window/Connections/ConnectionsView.swift` and deleting the lone source file. Single-screen-per-file simplification.
- **Per-provider state machine** (Connections) — each OAuth service's `ConnectionState` enum (8-9 cases for Linear/Slack, 9-10 for GitHub including device-flow-specific cases). UI switches per `service.state` inside per-provider card. No screen-level state machine.
- **Gain-framed empty state copy** — UX heuristic (loss-aversion mitigation): empty-state phrasing positioned as forward-looking opportunity ("You're solo for now" + invite-CTA), not deficit-framing ("No team members"). D3 applies in Team `.empty`.
- **Adaptive grid (LazyVGrid)** — SwiftUI `GridItem(.adaptive(minimum:maximum:))` — auto-fills row with as many columns as the content width allows. D3 Team grid: min 240 / max 360 → 3-col at 920pt window, 4-col at 1200pt+.
