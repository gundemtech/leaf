# Track 2 — D2: Navigation Shell + Home

**Date:** 2026-05-10
**Author:** Alex (with Claude)
**Status:** spec for review
**Track:** 2 (UI/UX redesign of Native Leaf macOS app)
**Phase:** D2 of 4 (D1 = Foundation [landed], D2 = Navigation Shell + Home, D3 = Data Surfaces, D4 = Identity & Config)
**Stacked on:** `feature/track-2-D1-design-foundation` (D1 не merged в `main`; Track 2 merges коллективно после D4)
**Branch:** `feature/track-2-D2-navigation-and-home`

## TL;DR

D1 поставил substrate (3-tier T1/T2/T3 token-система, 28 компонентов, 4 templates, TokensPreview). **D2 переписывает главное окно** — RootView (window shell) + Sidebar + Home — на этот substrate. Migration approach — Snapshot Replacement: остальные screens (Activity / Team / Connections / Organization / Settings / Profile / MenuBar / sheets / Onboarding) **не трогаются**, остаются на старом palette (D3/D4 redesign). Главная архитектурная перестройка — Home **переосмысляется с нуля**: вместо генерик 4-tile metric grid + 6 разнопалубных блоков — **4-section compact IA** (Hero current-state · Live Presence · Today summary · Recent sessions) под "numbers are quiet" принципом из D1 North Star. LeafWindowLayout (D1 template T1) промоутится из demo-only в actual app shell.

**Locale:** все UI labels / placeholders / button strings в Home/Sidebar/RootView — **English** (consistent с current product strings; localization — carry-over track). Russian — только для команд / комментариев в коде / spec'а.

## Vision recap (из D1 § "North Star")

> Leaf — это тихий профессиональный инструмент, который появляется когда нужен и исчезает когда нет.

D2 — первое реальное проявление этого vision'а в продукте. Юзер открывает Leaf и за 1 секунду понимает "где я сейчас" (Hero); за 5 секунд — "что снаружи / как день" (Live Presence + Today); если есть желание — скролит в детали (Recent sessions).

Ключевые принципы D1 которые D2 буквально применяет:
- **Color is a signal, not a wash** — accent.primary только в active/selected/CTA. Surface — нейтрал.
- **Numbers are quiet** — max 1 `LeafMetricAmbient` per section, остальные числа inline в narrative.
- **Glass as a quiet material** — wrappers (LeafCard, sidebar bg) на Material; не на каждой кнопке.
- **Motion is information** — нет ambient looping / shimmer / skeleton-pulse в loading states.

## Anti-patterns (won't-list для D2)

- ❌ **4-tile metric dashboard** — текущий `metricGrid` (Focus / Switching / AI / Streak в 4 GlassCard) — это ровно то что D1 spec § "Metric primitives" запрещает. **Удаляется**.
- ❌ **Provider 3-card grid** — текущий `ProvidersBlock` с тремя GlassCard для Linear/GitHub/Slack accumulated stats — fold'ится в Today section как inline rows.
- ❌ **Skeleton shimmer / pulse loading** — D1 §22. Loading state — простой ProgressView, без animated placeholder выкидывающегося в repeatForever.
- ❌ **Decorative gradients / neon glow halo** — нигде в D2.
- ❌ **Mascot illustrations в empty states** — `LeafEmptyState` (D1 organism O7) использует SF Symbol + текст, ничего больше.

## Scope

### В D2

| Файл | Action |
|---|---|
| `Leaf/Views/Window/RootView.swift` | rewrite — LeafWindowLayout shell |
| `Leaf/Views/Window/Sidebar.swift` | rewrite — LeafNavRow + 3 grouped sections |
| `Leaf/Views/Window/StatusPill.swift` | **DELETE** (replaced inline в RootView toolbar `LeafStatusPill`) |
| `Leaf/Views/Window/Home/HomeView.swift` | rewrite — 4-section structure |
| `Leaf/Views/Window/Home/MetricCard.swift` | **DELETE** (folds в `LeafMetricAmbient` + inline) |
| `Leaf/Views/Window/Home/PeakFocusChart.swift` | **DELETE** (peak hour становится inline в Today) |
| `Leaf/Views/Window/Home/LivePresenceWidget.swift` | rewrite на D1 organisms |
| `Leaf/Views/Window/Home/RecentSessionsBlock.swift` | rewrite на D1 organisms |
| `Leaf/Views/Window/Home/ProvidersBlock.swift` | **DELETE** (folds в Today section как provider rows) |
| `Leaf/Theme/Layouts/LeafWindowLayout.swift` | tweak — drop default `padding(LeafSpace.xl)` на detail (chrome ownership becomes per-view concern) |
| `scripts/check-tokens.sh` | extend scope (new dirs + file-level support) |
| `scripts/tests/test-check-tokens.sh` | extend self-test fixtures для file-level matching |

### НЕ в D2 (явно)

- **MenuBar dropdown** redesign — D4 (per D1 spec §49).
- **Sibling screens** (Activity / Team / Connections / Organization / Settings / Profile / WaitingForInviteView / GenerateInviteSheet / AcceptInviteSheet / Onboarding) — D3/D4. Live в shell без визуальных изменений.
- **Old palette удаление** (`Leaf/Theme/Colors.swift`, `Theme/Fonts.swift`, `Theme/GlassModifiers.swift`, `Leaf/Views/Window/Shared/GlassCard.swift`) — стабильны до ship D4 (когда последний consumer мигрирует). D2 их не трогает.
- **Swift Charts adoption** — carry-over в D3 если Activity потребует timeline graph.
- **Hourly time series** для sparklines per metric — Derived Insights Engine extension, отдельный track.
- **New InsightsReader queries** / расширение `InsightsSnapshot` — D2 — UI substrate-only, использует existing data.
- **Sharing / Invisible** wiring для `LeafStatusPill` — Phase 5.4 (когда `presence_outgoing` появится). В D2 stub'аем на `.idle` и `.active` only.
- **Per-event hourly sparklines** в Today section — отложено.
- **Brand mark redesign** — отдельный track (D1 же).

### Acceptance criteria

1. `⌘⌥T` Tokens Preview всё ещё открывается и рендерится без regressions (D1 substrate не сломан).
2. RootView рендерит новый shell на macOS 26 + (best-effort) macOS 14 — visual smoke.
3. Sidebar — 3 grouped sections (LEAF / COLLABORATION / ACCOUNT), selected row фон `LeafColor.accent.subtle`, hover `LeafColor.surface.raised`.
4. Home — все 4 sections рендерятся в `.loaded` state с full snapshot data.
5. Все 5 InsightsReader state-machine fallbacks visually работают: `.loading` / `.notConfigured` / `.empty` / `.error` / `.loaded`.
6. Toolbar `LeafStatusPill` корректно reflectит state (idle ↔ active flip когда recent session gating пересекает threshold).
7. `RemovedFromTeamBanner` full-screen takeover preserved (Phase 5.3.E).
8. `.onOpenURL` invite handling + `.scenePhase` clipboard probe preserved (Phase 5.5.B).
9. `⌘,` opens Settings via existing `OpenSettingsCommand` (preserved).
10. `just check-tokens` passes для всех D2-scope files; `just check-tokens-self-test` passes (включая новые file-level fixtures).
11. 5/5 xcodebuild schemes green (Leaf / LeafAgent / LeafCore / LeafCorePrivate / LeafMCP).
12. 1213 SPM tests baseline preserved (zero new tests — D2 — pure UI substrate).

## Aesthetic anchors

D1 anchors carry over:
- **Apple-native** через Liquid Glass system materials (LeafGlass wrappers + macOS 14 fallback).
- **Notion** через generous whitespace, content-first hierarchy, soft palette.
- **Linear** через precision, hover-state quality, monospace для IDs/timestamps.

D2-specific:
- **Sidebar** — Notion-pattern: section headers uppercase tracked label + grouped rows.
- **Home Hero** — single big primary (app name) + small caption row с inline metrics. Linear-style precision.
- **Today section** — typography-driven hierarchy (ambient hero → inline stack → list rows). Notion-style block composition.
- **Live Presence** — 3-col with vertical dividers — minimalist scanning grid.

## Information Architecture

### Window shell

```
Window("main")
  └─ RootView
       ├─ if removedFromOrg → RemovedFromTeamBanner (full-screen takeover, untouched)
       └─ else → LeafWindowLayout {
                   Sidebar(selection: $section)
                 } detail: {
                   detail(for: section)
                     .toolbar {
                       ToolbarItem(.primaryAction) {
                         LeafStatusPill(state: derivedStatusPillState)
                       }
                     }
                 }
                 .frame(minWidth: 920, minHeight: 620)
                 .onAppear { reader.refresh(); orgReader.refresh() }
                 .onOpenURL { ... }
                 .onChange(scenePhase) { ... }
```

Чрезвычайно важно — **`RemovedFromTeamBanner` остаётся external conditional wrap'ом**, не lift'ится в LeafWindowLayout. Tombstone — full-screen "ты больше не в org" event — семантически вне nav shell.

### Sidebar

3 grouped sections с uppercase headers (`LeafType.label`):

```
List(selection: $selection) {
  Section("LEAF") {
    LeafNavRow(.asset(...), title: "Home",         badge: nil, shortcut: nil, ...)
    LeafNavRow(.asset(...), title: "Activity",     ...)
  }
  Section("COLLABORATION") {
    LeafNavRow(.asset(...),  title: "Team",         ...)
    LeafNavRow(.asset(...),  title: "Connections",  ...)
    LeafNavRow(.system(...), title: "Organization", ...)
  }
  Section("ACCOUNT") {
    LeafNavRow(.asset(...), title: "Settings", ...)
    LeafNavRow(.asset(...), title: "Profile",  ...)
  }
}
.listStyle(.sidebar)
```

`WindowSection` enum остаётся как есть (7 cases). Группировка живёт исключительно в Sidebar view — каждая Section хардкодит свои `WindowSection` cases. `windowSection.title` / `.icon` / `.iconIsSystem` используются для построения LeafNavRow per-section.

LeafNavRow consumes (без модификации D1 organism):
- `accent.subtle` background — selected
- `surface.raised` background — hover
- `accent.primary` icon tint — selected
- `text.secondary` icon tint — rest

Badge slot и shortcut slot — пустые в D2 (всё equals `nil`). D3+ может wire'ить badge для Activity unread / etc.

### Home — 4-section IA

| # | Section | Отвечает на | D1 components |
|---|---|---|---|
| 1 | **Hero (current state)** | Где я сейчас | `LeafType.title.large` + caption row с inline-метриками |
| 2 | **Live Presence** | Что требует моего внимания снаружи | `LeafCard` + `LeafSection` + 3-col + `LeafIconLabel` + `LeafDivider` |
| 3 | **Today summary** | Как день прошёл | `LeafCard` + `LeafSection` + `LeafMetricAmbient` + `LeafMetricInline` + `LeafListRow` + `LeafDivider` |
| 4 | **Recent sessions** | Что я делал | `LeafCard` + `LeafSection` + `LeafListRow` + `LeafDivider` + `LeafEmptyState` |

Top-down scroll. Каждая section отвечает на ортогональный вопрос — нет дублирования.

## Section specs

### Section 1 — Hero (current state)

**Compute:** derive из `snapshot.recentSessions.first` + `snapshot.idleSecondsCurrent` (если поле есть; иначе heuristic: `now - session.end ≤ X` → active). См. § "Open Q" про threshold.

**Active session detection:** session "active" iff `session.end == nil` (in-progress, если ActivitySession поддерживает open-ended) ИЛИ `session.end ≥ now - LeafStatusPillTokens.activeThresholdSeconds` (default 60s, см. § "StatusPill migration"). Single source of truth — same threshold что использует toolbar's LeafStatusPill.

**Active state:**
```
Cursor                                           ← LeafType.title.large, text.primary
[LEAF-128] · 23 min · idle 0s                    ← caption row
   ^ LeafType.mono.small        ^ LeafType.body.small muted
```

`LEAF-128` — extracted из window title через existing `LinearIDExtractor` (Phase 4.7.A first-match `.extract`). Если match нет — показываем trimmed window title (truncationMode `.middle`). Если window title пустой — drop element entirely (caption становится `"23 min · idle 0s"`).

Timestamps formatted inline в English без units rendering ("23 min" / "1 h 4 min" / "12 h 32 min"). Idle сегмент omits если `idleSeconds < 5`.

**Idle state** (no fresh session):
```
Idle                                             ← LeafType.title.large, text.secondary tint
last: Cursor · 12 min ago                        ← caption row
```

**No-data state** (no sessions сегодня):
```
Leaf is listening                                ← LeafType.title.large, text.secondary
Connect a provider in Connections to enrich      ← caption row, no metrics
```

App icon в leading (опционально, decision при impl): `LeafIcon(asset: appIconForBundle(bundleID))` size `.lg`. Если icon resolution fails — drop, keep text-only hero.

### Section 2 — Live Presence

```swift
LeafSection(title: "RIGHT NOW") {
  LeafCard(variant: .regular) {
    HStack(alignment: .top, spacing: LeafSpace.xl) {
      column(provider: .github,  ...)
      LeafDivider(orientation: .vertical)
      column(provider: .linear,  ...)
      LeafDivider(orientation: .vertical)
      column(provider: .slack,   ...)
    }
  }
}
```

Per-column structure:
```
GITHUB                                           ← LeafType.label uppercase, text.tertiary
[👁] 3 PRs await your review                     ← LeafIconLabel, accent.primary tint
[↗] 2 of mine open                                ← text.tertiary tint
[🔔] 5 unread                                     ← text.tertiary tint
[checkmark.circle] checks: success                ← status.success tint
```

Tint discipline:
- `accent.primary` — needs attention (PRs awaiting, started issues)
- `status.success` — passing (checks)
- `status.danger` — DND, failing checks
- `status.warning` — urgent priority
- `text.tertiary` — informational (counts, status emoji)

Per-column states:
- **Connected + active**: full lines list (current logic preserved from `LivePresenceWidget`).
- **Connected + idle**: "All quiet" в `text.tertiary`.
- **Not connected**: "Not connected" в `text.tertiary`.

Section целиком hides если `snapshot.presenceState.isEmpty` (никто не connected) — hero уже намекнул "Connect a provider".

### Section 3 — Today summary

```
TODAY                                           ← LeafType.label uppercase
─────────────────────────────────────────────────
[LeafMetricAmbient]
4h 32m                                          ← uses LeafMetricAmbient's display typography (T3)
12 sessions · 3-day streak · ↑12% vs last week  ← LeafType.body.small, text.tertiary
                                  ^ trend in status.success/warning
─────────────────────────────────────────────────
Peak around 14:00 · 5.2× switching/hr · 38% with AI
                                                ← row of LeafMetricInline, middot-separated
─────────────────────────────────────────────────
[L]  Linear · 8 touched, 3 done, 67% follow-through    ← LeafListRow with provider icon leading
[G]  GitHub · 12 events, PR cycle 4.2h
[S]  Slack  · 24 msgs, 18m huddle, 5 reactions
```

**Provider row order:** Linear → GitHub → Slack — preserve existing snapshot order (matches current `LivePresenceWidget` and `ProvidersBlock` ordering; not alphabetical, but consistent с already-used pattern — юзеры адаптировались).

**Metric primitive choice:** focus today используется именно `LeafMetricAmbient` (D1 substrate MT2 — "большое тихое число + label, без card-shadow, без trending arrow"). `LeafMetricCard` (D1 substrate MT — card-shaped metric) **не используется в D2 Home** — это anti-pattern под "no 4-tile dashboard" rule. LeafMetricCard остаётся как D1 substrate organism (рендерится в TokensPreview), но D2 Home не consumes.

**LeafMetricAmbient** carries focus today (sum of topApps duration, как сейчас). Caption combines:
- session count ("12 sessions")
- streak ("3-day streak", omit if < 1)
- weekOverWeek delta ("↑12% vs last week", omit if < ±2%)

**Inline metric stack** (middot-separated, single line, ellipsis на overflow):
- `Peak around HH:00` — omit если `peakProductivityHour == nil`
- `5.2× switching/hr` — omit если switchRate == 0
- `38% with AI` — omit если aiActiveSeconds == 0

Обоснование omission'ов: degrade gracefully на пустых данных. На fresh install с одним провайдером юзер не видит ноликов.

**Provider list rows** — каждый = `LeafListRow`:
- leading: `LeafIcon(asset: providerLogo)` (linear-mark / github-mark / slack-mark из existing AssetCatalog)
- primary: composed inline phrase combining 2-4 stats, formatted без table-layout (текст с middots)
- trailing: omitted (плотность достаточна в primary)

Per-provider phrase composition (если все stats > 0):
- **Linear**: `"Linear · {issuesTouched} touched, {transitions.completed} done, {round(completionRate*100)}% follow-through"`. Если что-то zero — drop из phrase. Если provider целиком empty — row hide.
- **GitHub**: `"GitHub · {eventsCount} events, PR cycle {medianLabel}"`. Median omitted если `sampleCount == 0`.
- **Slack**: `"Slack · {msgs} msgs, {huddleMinutes}m huddle, {reactions} reactions"`. Same drop-zero rule.

`LeafDivider` между group'ами (между LeafMetricAmbient и inline stack, между inline stack и provider rows). Внутри group'ы (между provider rows) — light dividers через `LeafDivider(.subtle)` или просто spacing.

Section целиком hides если ни одного non-zero data point (no focus today + no provider data) — hero уже сказал "Leaf is listening".

### Section 4 — Recent sessions

```swift
LeafSection(title: "RECENT SESSIONS · TODAY") {
  LeafCard(variant: .regular) {
    if topSessions.isEmpty {
      LeafEmptyState(
        symbol: "clock.arrow.circlepath",
        title: "No sessions yet",
        description: "Switch between apps for a few minutes to start your timeline"
      )
    } else {
      VStack(spacing: 0) {
        ForEach(Array(topSessions.enumerated()), id: \.element.id) { idx, session in
          LeafListRow(
            leading: LeafIcon(asset: appIcon(session.bundleID)),
            primary: AppNameResolver.shared.displayName(for: session.bundleID),
            secondary: session.windowContext,    // window title / file context
            trailing: Text(formatDuration(session.duration))
                       .font(LeafType.mono.small)
                       .foregroundStyle(LeafColor.text.tertiary)
          )
          if idx < topSessions.count - 1 {
            LeafDivider().padding(.leading, ...)
          }
        }
      }
    }
  }
}
```

Top 8 sessions sorted by `start` desc (existing `RecentSessionsBlock` logic preserved).

**Window context** — `session.windowContext` (already on `ActivitySession` per Phase 4.10.B). Mono для file paths, regular text для window titles. Truncate с `.truncationMode(.middle)`.

### Hidden zero-data shape

If `snapshot.recentSessions.isEmpty && snapshot.presenceState.isEmpty && focusTotal == 0`:
- Hero: "Leaf is listening"
- Section 2/3/4 — hidden
- Spacer + LeafEmptyState внизу с CTA "Open Connections" (если providers не connected) или "Stay tuned" (providers есть, no events yet).

Это симметричная degradation: чем меньше данных, тем меньше Home shows.

## State machine UX

| State | Render |
|---|---|
| `.loading` | Section 1 (Hero) shows "Reading recent activity…" + ProgressView (system standard, no shimmer). Sections 2-4 — skeleton placeholder using `LeafEmptyState`-shape "—" в text.tertiary. **No animations** (D1 §22). |
| `.notConfigured(msg)` | Full-page `LeafEmptyState` centered: SF Symbol "link" + msg + `LeafButton(.primary)` "Open Connections" → triggers `windowState.section = .connections`. |
| `.empty(msg)` | Full-page `LeafEmptyState` centered: SF Symbol "leaf" + msg + caption "Leaf is collecting in the background". No CTA. |
| `.error(msg)` | `LeafBanner(type: .danger)` at top with "Couldn't load Home" title + msg description + inline action "Try again" → `reader.refresh()`. Below banner — last-known content **omitted** (simpler error recovery; if usability suffers add cache-last layer post-D2). |
| `.loaded(snapshot, _)` | Full 4-section render per IA above. |

**Loading details:** ProgressView centered в hero region, остальные sections show muted placeholders to give shape but no fake content. Не используем `LeafProgress` (D1 organism) для этой роли — `LeafProgress` для determinate progress, не для loading spinner.

## Window shell — LeafWindowLayout adoption

D1 substrate provides:
```swift
// Leaf/Theme/Layouts/LeafWindowLayout.swift
struct LeafWindowLayout<Sidebar: View, Detail: View>: View {
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        NavigationSplitView {
            sidebar()
                .padding(.horizontal, LeafSpace.sm)
                .padding(.vertical, LeafSpace.md)
                .navigationSplitViewColumnWidth(
                    min:   LeafWindowLayoutTokens.sidebarMinWidth,
                    ideal: LeafWindowLayoutTokens.sidebarIdealWidth,
                    max:   LeafWindowLayoutTokens.sidebarMaxWidth
                )
        } detail: {
            detail()
                .padding(LeafSpace.xl)              // ← REMOVED in D2
        }
        .background(LeafColor.surface.canvas)
    }
}
```

**D2 tweak:** убираем `.padding(LeafSpace.xl)` на detail closure. Chrome padding becomes per-view concern. Reasoning:
- D2-migrated Home owns its own outer padding (let's say `LeafSpace.xl` matching D1 spec) — но это inside HomeView's ScrollView, рядом с content paddings, не chrome.
- D3/D4 не-migrated screens (Activity / Team / Connections / etc) сейчас имеют свои внутренние paddings; layout-level padding на detail дублирует их → "double padding".
- Cleaner architecture: layout shell — split, canvas, sidebar chrome. Detail — opaque slot. Каждая screen sets своё.

Тkzен `LeafWindowLayoutTokens` (D1 substrate) sidebarMin/Ideal/Max widths остаются авторитативными, не меняются.

**RemovedFromTeamBanner** не lift'ится в LeafWindowLayout. RootView builds:
```swift
if case .removedFromOrg(let orgName) = orgReader.state {
    RemovedFromTeamBanner(orgName: orgName)
} else {
    LeafWindowLayout { Sidebar(...) } detail: { ... .toolbar { ... } }
        .frame(minWidth: 920, minHeight: 620)
        .onAppear { ... }
        .onOpenURL { ... }
        .onChange(scenePhase) { ... }
}
```

Toolbar attaches к detail content's modifier chain — `.toolbar` propagates up через NavigationSplitView semantics. Не нужен новый toolbar slot в LeafWindowLayout.

## StatusPill migration

Текущий `Leaf/Views/Window/StatusPill.swift` — Stage-2 stub (статичный "ACTIVE" placeholder, comment "real session timer wired in Stage 6"). Использует `.leafAccent` / `.leafLabelStyle()` / `.leafGlass(...)`. D1 organism `LeafStatusPill` (Composites/LeafStatusPill.swift) — full impl с idle/active/sharing/invisible states + pulse ring + reduce-motion respect.

**D2 удаляет custom StatusPill, использует LeafStatusPill inline в RootView toolbar:**

```swift
.toolbar {
    ToolbarItem(placement: .primaryAction) {
        LeafStatusPill(state: derivedStatusPillState(reader: reader))
    }
}

// Helper:
private func derivedStatusPillState(reader: InsightsReader) -> LeafStatusPillState {
    switch reader.state {
    case .loaded(let snapshot, _):
        if let mostRecent = snapshot.recentSessions.first,
           Date().timeIntervalSince(mostRecent.end) <= LeafStatusPillTokens.activeThresholdSeconds {
            return .active
        }
        return .idle
    case .loading, .empty, .notConfigured, .error:
        return .idle
    }
}
```

**activeThresholdSeconds** — новый T3 token в `LeafStatusPillTokens` (Phase 5.4 wiring пере-использует). Default — 60s. См. § "Open Q" про CGEventSource alignment.

`.sharing` / `.invisible` states — wire'ятся в Phase 5.4 (когда `presence_outgoing` появится). В D2 не используются.

## Migration tactic — In-place rewrite

**Принцип:** D2 переписывает D2-scope files in-place. Old palette files (Theme/Colors.swift, Theme/Fonts.swift, Theme/GlassModifiers.swift, Views/Window/Shared/GlassCard.swift) **не удаляются** — они референсятся D3/D4 screens до их migration. Финальный cleanup commit landит в D4 после ship D4 (или отдельным cleanup треком после D4).

D2-scope files после rewrite:
- Не import'ят `.leafBackground` / `.leafInk` / `.leafMuted` / `.leafAccentDeep` / `.leafSignal` / `.leafLabelStyle()` / `.leafGlass(...)` / `GlassCard` / `LeafGlassGroup`.
- Используют только D1 substrate: `LeafColor.*` / `LeafType.*` / `LeafSpace.*` / `LeafRadius.*` / `LeafElevation.*` / `LeafGlass.*` / `LeafMotion.*` + T3 component tokens + organisms.

**Удаляемые файлы (на эту фазу):**
- `Leaf/Views/Window/StatusPill.swift` — заменён `LeafStatusPill` инлайн в RootView.
- `Leaf/Views/Window/Home/MetricCard.swift` — fold'ится в `LeafMetricAmbient` + inline формы.
- `Leaf/Views/Window/Home/PeakFocusChart.swift` — peak hour становится одной строкой в Today inline metrics row.
- `Leaf/Views/Window/Home/ProvidersBlock.swift` — fold'ится в Today section provider rows.

**Stays файлы (rewrite):**
- `Leaf/Views/Window/Home/HomeView.swift` — overall structure rewrite.
- `Leaf/Views/Window/Home/LivePresenceWidget.swift` — internal rewrite на D1 organisms (interface preserved: input `PresenceUISnapshot`).
- `Leaf/Views/Window/Home/RecentSessionsBlock.swift` — internal rewrite на D1 organisms.
- `Leaf/Views/Window/RootView.swift` — shell rewrite.
- `Leaf/Views/Window/Sidebar.swift` — rebuild на LeafNavRow.

**LeafWindowLayout edit** (D1 substrate refinement on D2 stack — allowed since D2 stacks on D1):
- Drop `.padding(LeafSpace.xl)` line на detail closure.

## Token discipline guard extension

Сейчас `scripts/check-tokens.sh` covers только `Leaf/Theme/` + `Leaf/Views/Tokens/` (dir-level scope). D2 расширяется:

**New scope:**
- dir: `Leaf/Views/Window/Home/` (вся Home folder после rewrite)
- file: `Leaf/Views/Window/RootView.swift`
- file: `Leaf/Views/Window/Sidebar.swift`

**Script refactor:** добавить `SCOPE_FILES` array параллельно `SCOPE_DIRS`. `check_pattern` функция iterates оба array'а. File-level scope позволяет cherry-pick'нуть отдельные files без full-folder discipline (полезно когда mixed migration в same folder).

**Self-test** (`scripts/tests/test-check-tokens.sh`) — добавить fixtures для file-level matching: temp `RootView.swift`-подобный fixture с raw `.padding(40)` → must trigger fail; clean fixture → must pass. Existing dir-level fixtures continue to work.

**Old-palette enforcement (formal):** под "in-place rewrite drops old palette" discipline — расширяем guard двумя дополнительными patterns matching D2 scope:

- Pattern: `\.leaf(Background|Ink|Muted|Accent|AccentDeep|Signal|LabelStyle|Body|Title|Caption|Metric|Glass|GlassGroup)\b` — fail если встречается в SCOPE (D2-rewrite files используют ТОЛЬКО D1 substrate, не old palette references).
- Pattern: `\b(GlassCard|LeafGlassGroup)\b` — same enforcement.

Эти rules formalize: "файл миграл = ZERO old-palette refs". D3/D4 files unaffected (они вне SCOPE до их собственной phase). New self-test fixtures verify оба patterns trigger correctly.

## Out-of-scope для D2 (carry-over в D3/D4 / отдельные tracks)

- **MenuBar redesign** — D4.
- **Sibling screens** — Activity (D3), Team (D3), Connections (D3), Organization (D4), Settings (D4), Profile (D4), Onboarding (D4), sheets (D4).
- **Old palette deletion** — D4 cleanup (после migration last consumer).
- **Swift Charts adoption** — carry-over в D3 если Activity потребует.
- **Hourly time series для sparklines** — Derived Insights extension, отдельный track.
- **Sharing / Invisible status states** — Phase 5.4 (presence_outgoing).
- **Hero data shape — surface "current session" computed property** на InsightsSnapshot (если HomeView внутренний derive окажется messy) — рефактор carry-over.
- **macOS 14 visual smoke** — best-effort если 14 machine появится. Иначе compile-only validation.

## Open questions / risks

- **Active threshold для LeafStatusPill** (60s vs 5 min). 60s = "только что прервал session" → idle. 5 min = aligned с CGEventSource idle threshold. Решение: 60s (быстрее реагирует на "юзер ушёл"). Сделать configurable token `LeafStatusPillTokens.activeThresholdSeconds` для late-stage tuning.
- **Hero "current session" derivation** vs adding computed property to InsightsSnapshot. D2 derives in HomeView. Если становится messy (3+ derive рутин в HomeView) — surface как `snapshot.currentSession: CurrentSession?` в LeafCore — но это новая InsightsReader work, scope creep. Carry-over после D2 ship.
- **Window context "LEAF-128" extraction.** Re-used existing `LinearIDExtractor` (Phase 4.7.A) для substring match в window title. Если match нет — show trimmed window title (truncated в `.truncationMode(.middle)`). Если window title пустой — drop element entirely.
- **Today section provider rows ordering.** Linear → GitHub → Slack — preserve existing snapshot order (matches current `LivePresenceWidget` and `ProvidersBlock`). Не alphabetical, но consistent с already-used pattern. Refactor если smoke выявит лучший pattern (e.g. activity-volume-order).
- **macOS 14 testing matrix.** D1 risk перенесён. Best-effort если 14 machine доступна; else compile-only validation. Не блокер для merge.
- **Sidebar `Section` header rendering.** SwiftUI's `List`-в-`.sidebar` style auto-renders `Section` header в native sidebar styling. Custom `LeafType.label` styling требует override через `Text(...)` inside Section header. Implementation detail — повтор паттерн text-in-Section header.
- **LeafEmptyState centered placement** в HomeView для notConfigured/empty/error states. ScrollView с centered content требует frame trick (maxHeight: .infinity + alignment .center). Если становится bug-prone — wrap в HStack/VStack with Spacer'ами. Implementation detail.
- **Toolbar `LeafStatusPill` re-render frequency.** Derived state recomputes на каждый `reader.state` change. Если `recentSessions.first.end` shifts continuously (per-second ticks?) — could cause toolbar flicker. Mitigation: derived state takes только session existence + age bucket (`active` vs `idle`), не actual seconds count → state changes только на boundary crossing → no flicker.
- **D1 organism API verification.** Spec usage предполагает API shapes для `LeafCard` / `LeafSection` / `LeafListRow` / `LeafEmptyState` / `LeafIconLabel` / `LeafIcon` / `LeafMetricAmbient` / `LeafMetricInline` / `LeafBanner` / `LeafDot` / `LeafDivider`. D1 substrate landed но specific argument labels / slot names / variant enum cases в этом spec'е изображены illustratively. Stage 4 plan verifies actual API shape per organism file и адаптирует usage; substrate organisms **не модифицируются** в D2 (исключение — `LeafWindowLayout` per § "Window shell"). Если organism API не совпадает с spec usage — adapt usage в plan, не organism source.
- **InsightsSnapshot / ActivitySession field references.** Spec referenced fields (`recentSessions`, `presenceState`, `peakProductivityHour`, `switchRate`, `aiRatio`, `aiActiveSeconds`, `deepWorkStreak`, `weekOverWeekDelta`, `linearIssuesTouched`, `linearTransitions`, `linearCompletionRate`, `githubEventsCount`, `githubPRCycleStats`, `slackMessagesCount`, etc) per Discovery exist в LeafCore. `ActivitySession.windowContext` derivation (window title / file context) — verify в plan, fall back на `windowTitle` / `fileContext` separate properties если composite не доступен. Никакой новой Derived Insights work в D2 — pure UI substrate.

## Glossary

- **Snapshot Replacement migration** (D1 § "Migration approach") — D1 substrate ships без переезда existing views; D2/D3/D4 мигрируют свои views постепенно in-place. Old palette остаётся available для не-migrated views.
- **D2-scope files** — files перечисленные в § "Scope > В D2". Эти files в D2 — fully on D1 substrate (zero old palette refs). Все остальные files unchanged.
- **Idle / Active threshold** (для LeafStatusPill) — boundary за которой most-recent session считается "stale" → status pill flips active→idle. D2 default 60s; configurable via `LeafStatusPillTokens.activeThresholdSeconds`.
- **Chrome padding ownership** (LeafWindowLayout adoption) — после D2 tweak, layout shell не padd'ит detail content; per-view chrome padding owned by view itself. Полезно — avoid double-padding для D3/D4 не-migrated views.
