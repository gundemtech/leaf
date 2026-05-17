# Track-7 P4 — Layer B drill-downs design spec

**Status.** Draft — Stage 3 of 8-stage phase workflow.
**Date.** 2026-05-17.
**Branch.** `feature/track-7-P4-layerb-drilldowns` off P1 head `90180348`.

---

## §0 Branch parent rationale

P4 ветвится off P1 head `90180348` — **не** off `main`. На `main` отсутствует весь Track-7 P1 substrate (`HomeSurface` enum, `RouteCoordinator`, `SurfaceCard`, `SurfaceDetailLayout`, `DetailRange`, `SurfaceCardState`, `ClaudeCodeDetailScreen`, `LivePresenceWidget` в Track-7-обновлённой форме). Этот substrate живёт на `feature/track-7-P1-foundation-claude-code @ 90180348` и ждёт P11 collective acceptance gate для merge в `main`.

P3 (`feature/track-7-P3-work-state`) ветвилась off того же P1 head по идентичной причине. P4 повторяет этот pattern — parallel branch к P2-collapsed + P3, общий substrate root, collective merge через P11.

Wording в session prompt "off main, не off P3 head" интерпретируется как "off shared substrate root (P1 head), parallel to P3" — а не литерально off `main`, что сделало бы P4 невозможным без cherry-pick всего P1 stack.

---

## §1 Scope

**Один абзац.** LivePresenceWidget делает 3 column (Linear / GitHub / Slack) tappable, каждая ведёт в per-provider detail screen, переиспользующий `SurfaceDetailLayout`. Aggregates секции отображают существующие `linearActivity / githubActivity / slackActivity` breakdown'ы + provider-specific extras (`linearTransitions` для Linear, `ReviewActivityInsights.reviewActivity()` для GitHub, ничего экстра для Slack). GitHub + Slack detail screens рендерят sticky reauth banner поверх `SurfaceDetailLayout` когда `*ScopesReader.state == .connectedScopeOutdated(...)`. Linear scope drift не существует (`read` scope фиксирован), banner отсутствует.

**Substrate-only invariant (жёсткий).** Zero new event_kinds / zero new migrations / zero new MCP tools / zero new ShareEventTypeKey entries / zero new schema columns. P4 — pure UI surface поверх Layer B substrate, который полностью существует со времён Phase 4.2-4.6.

---

## §2 What's NOT in P4

- **Реальные daily timeseries в chart slot.** `LinearActivityBreakdown` / `GitHubActivityBreakdown` / `SlackActivityBreakdown` не имеют поля `daily: [Double]`. Mirror P1 ClaudeCode pattern: chart slot = placeholder text "Daily breakdown will appear here." P11 polish может промоутить через отдельный daily SQL helper (carry-over).
- **Cross-provider drill-down links** (`linked_prs` → tap → Linear issue). Текст рендерится inline в GitHub "Linked PRs" секции; clickable navigation = P8-collapsed carry-over в P11.
- **Notion / Jira / Figma columns.** `LayerBProvider` enum готов к расширению, но v1.0 — только 3 кейса.
- **Per-detail-screen MCP tool calls.** Все aggregates из in-memory `InsightsSnapshot` или прямого `DerivedInsights.linearActivity(period:) / .githubActivity(period:) / .slackActivity(period:) / .linearTransitions(period:)` query. `ReviewActivityInsights.reviewActivity()` — отдельный static API call.
- **Card-level rendering changes в Home Surfaces section.** Layer B не = capture surface, columns живут в `LivePresenceWidget` (отдельный block "RIGHT NOW"). `HomeSurface` enum НЕ расширяется.

---

## §3 Architecture

### §3.1 Routing

Новый public enum в LeafCore:

```swift
// Packages/LeafCore/Sources/LeafCore/Home/LayerB/LayerBProvider.swift
public enum LayerBProvider: String, CaseIterable, Hashable, Codable, Sendable, Identifiable {
    case linear
    case github
    case slack

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .linear:  "Linear"
        case .github:  "GitHub"
        case .slack:   "Slack"
        }
    }
}
```

`RouteCoordinator` (`Leaf/Models/RouteCoordinator.swift`) расширяется одним методом:

```swift
func pushHomeLayerBProvider(_ provider: LayerBProvider) {
    homePath.append(provider)
}
```

`HomeView`'s `HomeContent.NavigationStack` регистрирует второй `navigationDestination` (первый — `HomeSurface.self` через P1, P3 добавил третий через `WorkStateRoute` на своей branch):

```swift
.navigationDestination(for: LayerBProvider.self) { provider in
    detail(for: provider)
}
```

`detail(for:)` switch'ит на provider → возвращает `LinearDetailScreen()` / `GitHubDetailScreen()` / `SlackDetailScreen()`.

### §3.2 LivePresenceWidget tap target

`Leaf/Views/Window/Home/LivePresenceWidget.swift` — каждая column становится `Button` action'ом `coordinator.pushHomeLayerBProvider(.linear/.github/.slack)`. Column title row меняется с одиночного `Text(title)` на `HStack { Text(title); Spacer(); LeafIcon(systemName: "chevron.right", size: .sm, tint: LeafColor.text.tertiary) }`. (LeafIcon `Size` enum cases: `.sm/.md/.lg/.xl` — `.xs` отсутствует, matches P1 SurfaceCard chevron precedent.)

Tap всегда ведёт в detail screen — даже когда `snapshot.X == nil` (provider не connected). Detail screen рендерит свой `.empty` state с CTA "Connect <Provider>" → route в Connections settings.

Tap closure пробрасывается из `LivePresenceWidget` через свежий init parameter:

```swift
struct LivePresenceWidget: View {
    let snapshot: PresenceUISnapshot
    let onProviderTap: (LayerBProvider) -> Void
    // ...
}
```

`HomeContent` (HomeView.swift) вызывает: `LivePresenceWidget(snapshot:, onProviderTap: { coordinator.pushHomeLayerBProvider($0) })`. Wrapping `column()` ViewBuilder тоже принимает `provider: LayerBProvider` parameter, чтобы кнопка знала destination.

Accessibility: `.accessibilityElement(children: .ignore)` + `.accessibilityLabel("<Provider>: <connection state> · <line count> items")` + `.accessibilityAddTraits(.isButton)`.

### §3.3 Detail screen template

Каждый из 3 detail screens следует identical shape:

```swift
struct <Provider>DetailScreen: View {
    @State private var vm: <Provider>DetailViewModel

    init(vm: <Provider>DetailViewModel = .init()) {
        _vm = State(initialValue: vm)
    }

    var body: some View {
        Group {
            switch vm.state {
            case .loading:     ProgressView()...
            case .empty:       emptyState
            case .error(msg):  errorBanner(msg)
            case .loaded(headline, breakdown, extras):
                loadedContent(headline:, breakdown:, extras:)
            }
        }
        .onAppear { vm.reload() }
    }

    private func loadedContent(headline: DetailHeadline, breakdown: <X>, extras: <Y>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Sticky reauth banner — outside SurfaceDetailLayout's ScrollView.
            // Only renders for GitHub/Slack when scope is outdated and not dismissed.
            // Banner construction lives в DetailScreen (View) — VM хранит only `shouldShowScopeBanner`
            // bool. View имеет @Environment access к OAuthService instance (НЕ singleton — injected
            // через App composition root, см. HomeView lines 73-77 precedent).
            if vm.shouldShowScopeBanner {
                LeafBanner(
                    tone: .warning,
                    title: "<Provider> permissions need a refresh",
                    description: "\(missingCount) new event type\(s ?: "") \(is/are) blocked until you re-authorize.",
                    ctaTitle: "Re-authorize",
                    onCTA: { Task { await oauthService.connect(scopes: <Provider>ScopesService.requested()) } },
                    onDismiss: {
                        UserDefaults.standard.set(AppSessionID.current, forKey: <provider>ReauthBannerDismissKey)
                        vm.scopeBannerDismissed = true
                    }
                )
                .padding(.horizontal, LeafSpace.xxl)
                .padding(.top, LeafSpace.md)
            }

            SurfaceDetailLayout(
                title: LayerBProvider.<provider>.displayName,
                range: Binding(get: { vm.range }, set: { vm.range = $0 }),
                headline: headline,
                chart: { chartPlaceholder },
                aggregates: { aggregates(breakdown:, extras:) }
            )
        }
    }

    private var chartPlaceholder: some View {
        Text("Daily breakdown will appear here.")
            .font(LeafType.body.small)
            .foregroundStyle(LeafColor.text.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

### §3.4 Detail view-model template

Mirror `ClaudeCodeDetailViewModel`:

```swift
// Leaf/Models/LayerB/<Provider>DetailViewModel.swift

@MainActor
@Observable
final class <Provider>DetailViewModel {
    enum State: Equatable {
        case loading
        case loaded(headline: DetailHeadline, breakdown: <X>ActivityBreakdown, extras: <Y>)
        case empty
        case error(String)
    }

    private(set) var state: State = .loading
    var range: DetailRange = .default {
        didSet {
            guard range != oldValue else { return }
            reload()
        }
    }

    /// Per-launch dismiss state. Persisted в UserDefaults под session-ID-keyed
    /// pattern (mirror HomeView lines 87-92, 154 P1 precedent): dismiss → write
    /// AppSessionID.current into key; render → compare saved == current.
    /// Same UserDefaults key SHARED с HomeView reauthBannerDismissKey /
    /// slackReauthBannerDismissKey — dismiss в Home также скрывает banner в
    /// detail screen (одно-source-of-truth UX). App restart → новый session ID →
    /// banner возвращается если scope still outdated.
    /// Hardcoded strings: "github.reauth.bannerDismissedSessionID" и
    /// "slack.reauth.bannerDismissedSessionID" (комментарий явно объясняет
    /// shared-with-HomeView). Альтернатива hoist'а в shared constants — out-of-scope
    /// P4 (касается P1 substrate, минимизируем cross-branch surface).
    var scopeBannerDismissed: Bool = {
        guard let saved = UserDefaults.standard.string(forKey: <provider>DismissKey) else { return false }
        return saved == AppSessionID.current
    }()

    /// True when scope outdated AND not dismissed для current launch AND provider
    /// supports scope drift (Linear: всегда false — no scope drift concept).
    var shouldShowScopeBanner: Bool { ... }
    var missingCount: Int { ... }   // used in banner description string

    private let databaseURL: URL
    private let databaseConfig: DatabaseConfig
    private let databaseEncryption: EncryptionOptions?
    private let scopesReader: <Provider>ScopesReader?   // nil for Linear
    private let calendar: Calendar
    private let now: () -> Date
    private var task: Task<Void, Never>?
    private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "<provider>-detail")

    init(/* full injection block mirroring P1 */) { ... }

    func reload() {
        task?.cancel()
        state = .loading
        let interval = range.interval(now: now(), calendar: calendar)
        // ... open DB, query DerivedInsights.<X>Activity(period:), map to State
    }
}
```

`extras` payload содержит per-provider специфичные данные. **Каждый VM определяет
СВОЁ State enum** — `<Y>` это illustrative placeholder, реальные signatures
различаются:

- **Linear** State.loaded(headline:, breakdown: LinearActivityBreakdown, transitions: LinearTransitionBreakdown).
  `LinearTransitionBreakdown` — non-optional (DerivedInsights.linearTransitions(period:) throws → returns non-optional, имеет `.empty` static factory). В UI всё-нулевую `.empty` секцию скипаем conditionally.
- **GitHub** State.loaded(headline:, breakdown: GitHubActivityBreakdown, reviewActivity: ReviewActivityResult?).
  `ReviewActivityResult?` — optional, nil когда: (a) decode из raw dict вернул nil, (b) range == .month (см. §10 OQ — ReviewActivityPeriod не имеет .month case).
- **Slack** State.loaded(headline:, breakdown: SlackActivityBreakdown). Нет extras parameter.

`DerivedInsights.linearActivity / .githubActivity / .slackActivity / .linearTransitions` все имеют сигнатуру `throws -> X` (не optional, не async). VM reload pipeline ловит `Error` через do/catch внутри detached Task.

(Конкретные структуры — в §5 ниже.)

### §3.5 Headline formatter (per provider)

В LeafCore (matches P1 `ClaudeCodeHeadlineFormatter` placement):

```swift
// Packages/LeafCore/Sources/LeafCore/Home/LayerB/LinearHeadlineFormatter.swift
public enum LinearHeadlineFormatter {
    public static func headline(
        breakdown: LinearActivityBreakdown,
        range: DetailRange
    ) -> DetailHeadline {
        let value = "\(breakdown.issuesTouched) issue\(breakdown.issuesTouched == 1 ? "" : "s") touched"
        let trend = makeTrendString(wow: breakdown.wowDeltaPct, streak: breakdown.issueCloseStreak, ...)
        return DetailHeadline(value: value, trend: trend)
    }
}
```

Identical pattern для `GitHubHeadlineFormatter` и `SlackHeadlineFormatter`.

Headline trend rule (по spec master §5.4): omit trend annotation если prev period has <50% expected days. P4 v1.0 — упрощённый: показываем trend всегда когда `wowDeltaPct != nil`. Полная "50% expected days" логика — carry-over в P11 (требует separate `LeafCore.previousPeriodCompleteness()` helper).

---

## §4 Per-provider section content

Each detail screen's aggregates slot — single-page `VStack` из `LeafSection` блоков. Каждая секция conditionally rendered: пропуск если empty/nil.

### §4.1 LinearDetailScreen

**Headline:** `"<N> issue<s> touched"` + trend (`"<+N>% from last week · <K>-day close streak"` if applicable).

**Sections:**
1. **Activity** — 3-cell metric block:
   - `<issuesTouched>` total
   - `wowDeltaPct` formatted (e.g. "+12% wow")
   - `issueCloseStreak` formatted (e.g. "3-day streak")
2. **Transitions** — 4-row breakdown if `linearTransitions != nil && (started + completed + canceled + reopened > 0)`:
   - "Started: <N>"
   - "Completed: <N>"
   - "Canceled: <N>"
   - "Reopened: <N>"
3. **Top projects** — list (top 5 from `byProject`) if `!byProject.isEmpty`. Each row: `LeafIconLabel(.system("folder"), title: project.name, trailing: "\(project.count)")`.
4. **Top status** — list (top 5 from `byStatus`) if `!byStatus.isEmpty`. Each row: status name + count.
5. **Completion duration** — LatencyStats block (median/avg/max) if `completionDurationStats != nil`. Each value formatted as duration ("3.2d median · 4.1d avg · 9d max").

**Empty state.** Если `breakdown.issuesTouched == 0`: рендерим `LeafEmptyState` с title "No Linear activity yet" + description "Once you touch a Linear issue in this period, it'll show up here."

### §4.2 GitHubDetailScreen

**Headline:** `"<N> event<s>"` + trend (`"<+N>% wow · <K>-day commit streak"`).

**Sections:**
1. **Activity** — 3-cell metric block (eventsCount / wowDeltaPct / commitStreak).
2. **PR cycle** — LatencyStats (median/avg/max) if `prCycleStats != nil`. Formatted as duration.
3. **Review activity** — block из `ReviewActivityInsights.reviewActivity(database:period:)`:
   - "Reviews submitted: <N>"
   - "Review comments: <N>"
   - "Threads resolved: <N>"
   - Конкретно рендерится только если total > 0.
   - **Period mapping ограничение:** `ReviewActivityPeriod` имеет cases `.today` / `.yesterday` / `.last7Days` — НЕТ `.month` equivalent (см. `ReviewActivityInsights.swift` lines 32-47). Mapping:
     - `DetailRange.today` → `ReviewActivityPeriod.today`
     - `DetailRange.week` → `ReviewActivityPeriod.last7Days`
     - `DetailRange.month` → `ReviewActivityPeriod` mapping отсутствует — VM пропускает call, secция рендерится как "Review activity available for Today / Week views" placeholder (или secция полностью скрыта). См. §10 OQ.
4. **Review delay** — LatencyStats if `reviewDelayStats != nil`.
5. **Top repos** — list (top 5 from `byRepo`).
6. **By event kind** — list (top 5 from `byEventKind`). Event kind names humanized через snake_case → Title Case helper.
7. **Linked PRs** — list из `reviewActivity.linked_prs` если не пусто. Each row: `"<repo> #<pr_number> → <linked_linear_id>"` или без linked_linear_id если nil. **No tap target в v1.0** (clickable cross-link = P11 carry-over).

**Empty state.** Если `breakdown.eventsCount == 0` AND review counts all zero: same `LeafEmptyState` pattern.

**Scope drift banner.** Когда `GitHubScopesReader.state == .connectedScopeOutdated(missing: ...)` AND saved dismiss session-ID != AppSessionID.current.

`LeafBanner` API (real shape per `Leaf/Theme/Layouts/LeafBanner.swift`):

```swift
LeafBanner(
    tone: .warning,
    title: "GitHub permissions need a refresh",
    description: "\(missing.count) new event type\(s) \(is/are) blocked until you re-authorize.",
    ctaTitle: "Re-authorize",
    onCTA: {
        Task { await githubOAuth.connect(scopes: GitHubScopesService.requested()) }
    },
    onDismiss: {
        UserDefaults.standard.set(AppSessionID.current,
                                  forKey: "github.reauth.bannerDismissedSessionID")
        vm.scopeBannerDismissed = true
    }
)
```

`githubOAuth` — `@Environment(GitHubOAuthService.self)` injected на `GitHubDetailScreen` (mirror HomeView lines 74). НЕ singleton (`shared`-accessor отсутствует). Detail screen objавляет environment и pробрасывает в LeafBanner inline (без переноса в VM — VM не имеет access к environment).

Dismiss key string `"github.reauth.bannerDismissedSessionID"` shared с HomeView (same UserDefaults key). Hoist константы в shared module — out-of-scope P4 (touches P1 substrate); комментарий явно объясняет shared-key intent.

### §4.3 SlackDetailScreen

**Headline:** `"<N> message<s>"` + trend (`"<huddleMinutes>m huddle · <K>-day participation streak"` если активны).

**Sections:**
1. **Activity** — 4-cell metric block (messagesCount / wowDeltaPct / reactionsReceived / huddleParticipationStreak).
2. **Huddle** — total huddleMinutes + huddleSessionStats LatencyStats (median/avg/max session duration). Renders если `huddleMinutes > 0`.
3. **Top channels** — list (top 5 from `byChannel`). DM channels уже anonymized как "DM" bucket до записи (per ADR-010, Phase 4.4.A.3).

**Empty state.** Если `messagesCount == 0 && huddleMinutes == 0`: `LeafEmptyState` "No Slack activity yet".

**Scope drift banner.** Mirror GitHub — `SlackScopesReader.state` + `SlackOAuthService` via `@Environment` (mirror HomeView line 77). `LeafBanner(tone: .warning, title: "Slack permissions need a refresh", description: ..., ctaTitle: "Re-authorize Slack", onCTA: { Task { await slackOAuth.connect() } }, onDismiss: { UserDefaults.standard.set(AppSessionID.current, forKey: "slack.reauth.bannerDismissedSessionID"); vm.scopeBannerDismissed = true })`. Same shared-key intent с HomeView.

---

## §5 Privacy / ADR-010 walkback

**No new walkback fence в P4.** Обоснование:

1. P4 потребляет ИСКЛЮЧИТЕЛЬНО existing breakdown types (`LinearActivityBreakdown`, `LinearTransitionBreakdown`, `GitHubActivityBreakdown`, `SlackActivityBreakdown`, `ReviewActivityInsights` dict). Эти типы уже fenced на event-layer через `RelayBodyLeakageTests` (Track-3 D1-D4 + Track-6) + `DispatchCoverageTests` (parity fence для body kinds).

2. UI-уровневые wrappers (DetailHeadline, State enum) — local-UI only, не envelope-bound, не пишутся в `presence_state` table, не broadcast'ятся через relay. Mirror walkback fence над ними был бы redundant с уже-существующим event-layer fence.

3. P3 добавлял fence потому что D3 detector substrate был **first contact** с детектор-output данными (Decision/OpenQuestion/Blocker/WhereStoppedSnapshot). У P4 нет аналогичного "first contact" — все типы downstream от уже fenced event payloads.

**Stage 7 verification gate (обязательно).** Privacy walkback grep по P4 file scope:

```bash
grep -nrE "commit_message_body|attachment_body|review_body|email_subject|message_text|note_body|content|preview" \
    Packages/LeafCore/Sources/LeafCore/Home/LayerB/ \
    Leaf/Models/LayerB/ \
    Leaf/Views/Window/SurfaceDetail/LayerB/
```

Expected: 0 hits. Если hits — stop, investigate, либо drop поле либо документировать как known-safe (e.g. comment-only mention).

---

## §6 Type additions surface

Всё, что P4 добавляет публично (LeafCore) или internal (Leaf):

### §6.1 LeafCore (public surface)

| Type | Kind | Purpose |
|---|---|---|
| `LayerBProvider` | enum | Route discriminator + display name |
| `LinearHeadlineFormatter` | namespace enum | static `headline(breakdown:range:) -> DetailHeadline` |
| `GitHubHeadlineFormatter` | namespace enum | same |
| `SlackHeadlineFormatter` | namespace enum | same |
| `ReviewActivityResult` | struct | Typed wrapper над `ReviewActivityInsights.reviewActivity()` dict (см. §6.3) |

`Equatable + Hashable + Sendable` для всех struct'ов / enum'ов. `Codable` опционально для `LayerBProvider` (для NavigationPath persistence в будущем).

### §6.2 Leaf-side (internal)

| Type | Kind | Purpose |
|---|---|---|
| `LinearDetailViewModel` | `@MainActor @Observable` class | Detail screen state |
| `GitHubDetailViewModel` | same | Detail screen state |
| `SlackDetailViewModel` | same | Detail screen state |
| `LinearDetailScreen` | SwiftUI View | Detail screen body |
| `GitHubDetailScreen` | same | Detail screen body |
| `SlackDetailScreen` | same | Detail screen body |

### §6.3 ReviewActivityResult

Сейчас `ReviewActivityInsights.reviewActivity()` возвращает `[String: Any]`. P4 вводит typed decode wrapper (только public type, не новая method/event):

```swift
public struct ReviewActivityResult: Equatable, Sendable {
    public let periodLabel: String
    public let reviewsSubmittedCount: Int
    public let reviewCommentsCount: Int
    public let reviewThreadResolvedCount: Int
    public let byRepo: [RepoEntry]
    public let linkedPRs: [LinkedPREntry]

    public struct RepoEntry: Equatable, Sendable, Hashable {
        public let repo: String
        public let reviews: Int
        public let comments: Int
        public let threads: Int
    }

    public struct LinkedPREntry: Equatable, Sendable, Hashable {
        public let repo: String
        public let prNumber: Int
        public let linkedLinearID: String?
    }

    /// Decode raw [String: Any] dict from ReviewActivityInsights.reviewActivity().
    /// Returns nil if dict shape doesn't match expected schema.
    public static func decode(_ dict: [String: Any]) -> ReviewActivityResult? { ... }
}
```

Decoder = pure function над dict. Tests в `LeafCoreTests/ReviewActivityResultTests.swift`.

---

## §7 Testing strategy

### §7.1 Unit tests (SPM)

Added to `Packages/LeafCore/Tests/LeafCoreTests/`:

| Test file | What it covers | Target test count |
|---|---|---|
| `LayerBProviderTests.swift` | enum cases, displayName, rawValue, Hashable, CaseIterable | ~6 |
| `LinearHeadlineFormatterTests.swift` | headline value formatting (singular/plural, zero state), trend with/without wow, with/without streak | ~10 |
| `GitHubHeadlineFormatterTests.swift` | same shape | ~10 |
| `SlackHeadlineFormatterTests.swift` | same shape | ~10 |
| `ReviewActivityResultTests.swift` | decoder roundtrip (full schema, missing optional fields, malformed dict → nil) | ~12 |

**Total SPM net new:** ~48 tests. Target acceptance criteria: ≥30 net new (mirror P3 §7.2 AC-2).

### §7.2 No new RelayBodyLeakageTests / DispatchCoverageTests entries

Per §5 above. Stage 7 verification gate covers via grep.

### §7.3 No XcodeTest UI tests

Per session prompt + master §13: manual smoke per-provider A–F (UI tests not in P4 scope).

### §7.4 Acceptance smoke (manual, Stage 7 + P11 gate)

Per master spec §13.1 "P8-collapsed" row, per provider (Linear / GitHub / Slack), A–F:

- **A. Column tap activates drill-down.** Tap GITHUB column → `GitHubDetailScreen` push'ится на homePath. Same for LINEAR / SLACK.
- **B. Range tab toggle re-queries.** В detail tap `Week` → `Month` → данные обновляются (`vm.state = .loading` → `.loaded` с другими числами). Не теряем focus / state.
- **C. Back preserves Home scroll position.** Pop из detail → Home возвращается в exact previous scroll position. SwiftUI NavigationStack default behavior — должно работать out-of-the-box.
- **D. GitHub reauth banner triggers.** Revoke a GitHub scope в Settings → GitHub → reload `GitHubDetailScreen` → sticky banner появляется outside ScrollView. Tap "Reconnect" → запускается OAuth flow. Tap X → banner dismiss'ится session-local. Pop+re-push → banner возвращается если scope still outdated.
- **E. Slack reauth banner triggers.** Same shape as D.
- **F. Privacy walkback grep returns 0 hits.** Per §5.

Linear не имеет D/E (нет scope drift) — A/B/C/F только.

---

## §8 File layout (concrete)

```
docs/superpowers/specs/
    2026-05-17-track-7-P4-layerb-drilldowns-design.md  (this file)

Packages/LeafCore/Sources/LeafCore/Home/LayerB/
    LayerBProvider.swift
    LinearHeadlineFormatter.swift
    GitHubHeadlineFormatter.swift
    SlackHeadlineFormatter.swift
    ReviewActivityResult.swift

Packages/LeafCore/Tests/LeafCoreTests/
    LayerBProviderTests.swift
    LinearHeadlineFormatterTests.swift
    GitHubHeadlineFormatterTests.swift
    SlackHeadlineFormatterTests.swift
    ReviewActivityResultTests.swift

Leaf/Models/LayerB/
    LinearDetailViewModel.swift
    GitHubDetailViewModel.swift
    SlackDetailViewModel.swift

Leaf/Views/Window/SurfaceDetail/LayerB/
    LinearDetailScreen.swift
    GitHubDetailScreen.swift
    SlackDetailScreen.swift

Modified files (existing on P1 head):
    Leaf/Models/RouteCoordinator.swift       (+ pushHomeLayerBProvider)
    Leaf/Views/Window/Home/HomeView.swift    (+ navigationDestination(for: LayerBProvider.self) + onProviderTap closure)
    Leaf/Views/Window/Home/LivePresenceWidget.swift  (column → Button, title HStack + chevron, onProviderTap parameter)
```

**Zero modifications в `Packages/LeafCore` substrate (HomeSurface, SurfaceCard, SurfaceDetailLayout, DetailRange, SurfaceCardState).** P1 substrate осталось touched только Leaf-side (RouteCoordinator + HomeView + LivePresenceWidget) — это safe для P11 collective merge.

---

## §9 Implementation order (Stage 5)

Per session prompt: Linear → GitHub → Slack (simplest scope-drift к самому богатому). Внутри каждого provider'а — TDD per step, sequential:

**Task 1 — LayerBProvider enum + tests (LeafCore).**
- `LayerBProvider.swift` + `LayerBProviderTests.swift`
- Acceptance: SPM `cd Packages/LeafCore && swift test` green, new tests pass.

**Task 2 — Provider headline formatters + tests (LeafCore, 3 files together).**
- `LinearHeadlineFormatter.swift`, `GitHubHeadlineFormatter.swift`, `SlackHeadlineFormatter.swift`
- Соответствующие tests.

**Task 3 — ReviewActivityResult decoder + tests (LeafCore).**
- `ReviewActivityResult.swift` + `ReviewActivityResultTests.swift`

**Task 4 — RouteCoordinator extension + HomeView navigationDestination wiring.**
- `pushHomeLayerBProvider(_:)` + `navigationDestination(for: LayerBProvider.self)`.
- Заглушка `detail(for:)` возвращает `LeafEmptyState` "Coming soon" — пока detail screens не landed.

**Task 5 — LivePresenceWidget tappability.**
- Column → Button + chevron в title HStack + `onProviderTap` parameter.
- HomeContent передаёт closure.

**Task 6 — LinearDetailViewModel + LinearDetailScreen + integration.**
- `detail(for: .linear)` теперь возвращает реальный screen.
- Manual smoke A/B/C/F per §7.4.

**Task 7 — GitHubDetailViewModel + GitHubDetailScreen + integration.**
- Includes scope drift banner wire-up через `GitHubScopesReader` + `@Environment(GitHubOAuthService.self)` + UserDefaults dismiss key shared с HomeView.
- ReviewActivityInsights query пропускается при `range == .month` (см. §4.2).
- Manual smoke A/B/C/D/F.

**Task 8 — SlackDetailViewModel + SlackDetailScreen + integration.**
- Includes scope drift banner wire-up через `SlackScopesReader` + `@Environment(SlackOAuthService.self)` + UserDefaults dismiss key shared с HomeView.
- Manual smoke A/B/C/E/F.

**Task 9 — Stage 7 verification gate (no commit, just check).**
- 3/3 xcodebuild schemes green (Leaf / LeafAgent / LeafMCP).
- SPM test count delta ≥30 net new vs baseline.
- `just check-tokens` green (helping P2-collapsed waiver carries through).
- Privacy walkback grep returns 0 hits.
- Substrate-only invariant — no ShareEventTypeKey/migration/MCP/event_kind diffs.

**Task 10 — Stage 8 Ship commit + branch push + current-state update.**
- Final commit с подробным message + `git push origin HEAD`.
- `.claude/shared/current-state.md` entry в начало.
- **НЕ мержим в main** — ждёт P11 collective acceptance gate.

---

## §10 Open questions / known limitations

1. **Headline trend "<50% expected days" rule.** P4 v1.0 skips full rule — surface trend всегда когда `wowDeltaPct != nil`. Полное правило в P11 polish (требует `LeafCore.previousPeriodCompleteness(period:)` helper, separate scope).
2. **Daily chart slot — placeholder only.** Real daily-count sparklines = post-P11 carry-over (требует daily SQL helpers в LeafCorePrivate).
3. **Cross-provider linked PRs не clickable в v1.0.** Inline text only. Clickable navigation (tap → Linear issue detail) = P11 carve-over.
4. **`GitHubOAuthService` / `SlackOAuthService` injected через `@Environment`.** НЕ singletons (`shared`-accessor отсутствует). P4 detail screens объявляют `@Environment(GitHubOAuthService.self) private var githubOAuth` (mirror HomeView line 74) и вызывают `Task { await githubOAuth.connect(scopes: GitHubScopesService.requested()) }` inline в `LeafBanner.onCTA`. Composition root (App.swift / WindowState init) уже инжектит эти environments — P4 их потребляет, не модифицирует.
5. **Empty state CTA "Connect <Provider>".** Routes via `coordinator.route(.connections, windowState:)` — тапает Settings → Connections section. Mirror existing `AppRoute.connections` case (P1 substrate).
6. **ReviewActivityPeriod has no `.month` case.** GitHub detail при range == .month скрывает "Review activity" секцию (или показывает placeholder "Review activity available for Today / Week views only"). Расширение `ReviewActivityPeriod` enum'а с `.last30Days` case + добавление SQL helper для 30-day window — отдельный track (касается substrate уровня, scope creep для P4). v1.0 graceful skip.
7. **Reauth banner dismiss key shared с HomeView через hardcoded strings.** Идеально hoist'нуть в shared `Leaf/Models/ReauthBannerKeys.swift` constant, но это touches P1 substrate (HomeView refactor). v1.0 — hardcoded strings с явным comment "shared with HomeView reauthBannerDismissKey". P11 carry-over hoist в shared constants.

---

## §11 Risks / mitigations

| Risk | Mitigation |
|---|---|
| `ReviewActivityResult.decode` падает на изменении `ReviewActivityInsights` dict shape | Возвращает `nil` graceful. UI рендерит "Review activity unavailable" placeholder. |
| Linear scope drift существует в future версии API | `LinearDetailViewModel.scopeBanner` возвращает nil unconditionally в v1.0; добавим `LinearScopesReader` когда понадобится. |
| Banner state теряется на app suspend/resume | По дизайну: session-local. Re-suspend → banner возвращается. ОК для warning UX. |
| Manual smoke на real production accounts требует real Linear/GitHub/Slack workspaces | Smoke выполняется на dev'овском Mac автора, acceptance — Dmitrii + Anton. Same precedent как Track-3 D1-D4. |
| `SurfaceDetailLayout` API changes между P1 и P4 ship dates | P4 фризим API surface: только public params (title/range/headline/chart/aggregates). Если P11 collective merge показывает conflict — reconcile manually, не реактивно. |

---

## §12 P11 acceptance gate (collective)

P4 не merge'ится в `main` соло. Ждёт P11 acceptance gate, который объединит P1 + P2-collapsed + P3 + P4 + master design spec в один collective merge. Acceptance criteria для P4 (один из P11 rows):

- 3/3 xcodebuild schemes green
- SPM test count delta ≥30 net new
- `just check-tokens` green
- Privacy walkback grep returns 0 hits
- Substrate-only invariant verified (no event_kind / migration / MCP tool / ShareEventTypeKey / schema column diffs)
- Manual A-F smoke per provider passes (D/E for GitHub/Slack only)
- Independent end-of-branch code review accepts (with or without nits)
- Current-state.md entry written

---

## §13 Carry-overs to P11 / post-merge

- Headline trend `<50% expected days` rule (full implementation)
- Real daily sparkline data в chart slot (requires LeafCorePrivate `dailyXxxCounts(period:)` SQL helpers)
- Cross-provider linked PRs clickable navigation (tap PR row → Linear issue → drill-down)
- `WorkStateHeadlineFormatter` hoist to LeafCore (P3 carry-over, parallel issue)
- `LinearScopesReader` if/when Linear OAuth scope expands beyond `read`
- Localizable.strings entries (P11 polish — `home.layerb.<provider>.*` keys)

---

*End of spec.*
