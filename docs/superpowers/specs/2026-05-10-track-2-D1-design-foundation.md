# Track 2 — D1: Design Foundation

**Date:** 2026-05-10
**Author:** Alex (with Claude)
**Status:** spec for review
**Track:** 2 (UI/UX redesign of Native Leaf macOS app)
**Phase:** D1 of 4 (D1 = Foundation, D2 = Navigation Shell + Home, D3 = Data Surfaces, D4 = Identity & Config)

## TL;DR

Полный rewrite дизайн-языка нативной macOS-апки Leaf. D1 — это substrate: **atomic 3-tier токен-система** (primitive → semantic → component), **24 компонента + 4 templates** (atoms / molecules / organisms / metric primitives / templates), **Tokens Preview** debug-only screen за `⌘⌥T`, **light + dark** с system sync. Существующие screens **не трогаются** в D1 (Snapshot Replacement migration) — они мигрируют per-phase в D2/D3/D4. Минимальный таргет — macOS 14, polish — macOS 26 через Liquid Glass.

## North Star (vision для всех 4 phases)

> Leaf — это тихий профессиональный инструмент, который появляется когда нужен и исчезает когда нет.

Пять принципов которые держат D1-D4 вместе:

1. **Glass as a quiet material.** Liquid Glass — это *основа поверхностей* (sidebar, cards, sheets, modals), а не *декор кнопок*. Apple System Materials с нашим тинтом — основной язык. Glass даёт глубину macOS 26, но не нагнетает.
2. **Color is a signal, not a wash.** Fresh-leaf green появляется **только** в активных состояниях (selected nav, primary CTA, focus indicator, "live"-statusy). Surfaces сами — тёплый нейтрал в light, charcoal в dark. Никаких decorative gradients. Никогда glow halo.
3. **Typography carries hierarchy.** SF Pro Display/Text/Mono. Размер + weight + tracking — этого хватает. Никакого "разнобоя стилей чтоб было живо".
4. **Motion is information.** Каждая анимация коммуницирует state change или иерархию ("это попало сюда оттуда"). Нет ambient looping, нет shimmer на load, нет sparkle micro-rewards. Springs Apple-grammar, durations measured.
5. **Numbers are quiet.** Никаких 4-tile dashboards с trending-arrow + sparkline. Числа живут **внутри narrative** (фраза, предложение) или **ambient peripheral** (sidebar peek, status pill, in-context pill). Метрика с контекстом > метрика на пьедестале.

## Anti-patterns (явный won't-list для D1-D4)

- ❌ **AI-glitter эстетика** — purple-pink gradient blobs, sparkle ✨ icons, glitter decoration, neon glow halo. "GenAI hype 2024" афиша.
- ❌ **Generic SaaS dashboard** — белые cards + хугое число + trending arrow + sparkline (Tailwind UI templates). Round bubble buttons с neon glow.
- ❌ **Stock illustrations / Lottie mascots** — плоские векторные character-illustrations, animated mascots, generic empty-states ("space astronaut" / "happy person at desk" / friendly robot). Empty states используют SF Symbols + текст, точка.
- ❌ **Glassmorphism на всём** — frosted glass поверх каждой кнопки и карточки. Glass — на surface-уровне (sidebar, sheet, hero), не на каждом atomic component.

## Scope

### В D1

- `Leaf/Theme/Tokens/` — все token-файлы (primitive, semantic, component-level)
- `Leaf/Theme/Primitives/` — atoms (`LeafIcon`, `LeafDot`, `LeafDivider`)
- `Leaf/Theme/Composites/` — molecules + organisms (`LeafButton`, `LeafCard`, `LeafBanner`, etc)
- `Leaf/Theme/Layouts/` — templates (`LeafWindowLayout`, `LeafSheetLayout`, `LeafMenuBarLayout`, `LeafOnboardingStepLayout`)
- `Leaf/Views/Tokens/TokensPreviewScreen.swift` + sub-views — debug-only storybook за `⌘⌥T`
- `Assets.xcassets` — добавление новых color sets (light + dark) рядом со старыми (`BrandCream` etc остаются)
- Pre-commit guard `scripts/check-tokens.sh` — проверка что в `Theme/` и `Views/Tokens/` нет raw colors / raw spacing
- D1 spec doc + D1 plan doc

### НЕ в D1 (явно)

- Перерисовка существующих экранов (Home / Activity / Team / Connections / Organization / Settings / Profile) — это D2/D3/D4
- Изменение navigation structure (NavigationSplitView → что-то другое) — это D2
- Изменение MenuBar dropdown — это D4
- Onboarding redesign — это D4
- Sheets (AcceptInvite / GenerateInvite) — это D4
- Иконки/illustrations кастомные — используем SF Symbols + provider-logos уже существующие
- Logo / brand mark redesign — отдельный трек
- Charts wrappers (Swift Charts) — добавим в D2 при дизайне Home или признаём что system Charts хватает

### Acceptance criteria

1. `⌘⌥T` открывает Tokens Preview screen, на нём видно все 24 компонента + 4 templates в light + dark + macOS 14 fallback + macOS 26 polish.
2. Существующие экраны не сломаны — проект компилируется, рантайм работает, все SPM tests + xcodebuild schemes зелёные.
3. Token discipline guard — `scripts/check-tokens.sh` фейлится если в `Leaf/Theme/` или `Leaf/Views/Tokens/` встречается raw color literal или raw spacing/radius number.
4. Visual smoke на двух macOS версиях (14.x и 26.x) — TokensPreview рендерится без поломок, glass fallback корректный, motion fallback (reduceMotion) работает.

## Aesthetic anchors

- **Apple-native** через Liquid Glass system materials
- **Notion** через generous whitespace, content-first hierarchy, soft palette tones
- **Linear** через precision, hover-state quality, monospace для IDs/timestamps

Не "одно из этих", а **гибрид**: Apple-glass shell + Notion-style блоки + Linear-style точность когда зумится в детали.

## Token system

### Three-tier discipline

- **Tier 1 — Primitive** (raw values): `LeafPrimitive.green.500 = #22C55E`. **Internal-only**, нельзя использовать прямо в UI коде.
- **Tier 2 — Semantic** (intent-based): `LeafColor.surface.canvas`, `LeafType.title.large`, `LeafSpace.lg`. **Можно** использовать в layout shells (window background, page padding) где нет компонента в смысле atomic design.
- **Tier 3 — Component** (component-specific): `LeafButton.Primary.Rest.background`. **Обязательно** для всех component properties в UI коде. Файл per-component в `Theme/Tokens/Components/`.

### Naming convention

Namespaced enum syntax:

```swift
LeafColor.surface.canvas             // T2
LeafColor.text.primary
LeafColor.accent.primary
LeafButton.Primary.Rest.background    // T3
LeafButton.Sizing.heightMedium
```

### File structure

```
Leaf/Theme/Tokens/
├── LeafPrimitive.swift                 // T1 raw values, internal
├── LeafColor.swift                     // T2 semantic colors
├── LeafType.swift                      // T2 typography
├── LeafSpace.swift                     // T2 spacing scale
├── LeafRadius.swift                    // T2 corner radii
├── LeafElevation.swift                 // T2 shadow styles
├── LeafGlass.swift                     // T2 glass material wrappers + fallback
├── LeafMotion.swift                    // T2 springs, durations, easings
└── Components/                         // T3 component tokens
    ├── LeafButtonTokens.swift
    ├── LeafCardTokens.swift
    ├── LeafPillTokens.swift
    ├── LeafBadgeTokens.swift
    ├── LeafToggleTokens.swift
    ├── LeafInputTokens.swift
    ├── LeafSelectTokens.swift
    ├── LeafAvatarTokens.swift
    ├── LeafNavRowTokens.swift
    ├── LeafListRowTokens.swift
    ├── LeafStatusPillTokens.swift
    ├── LeafBannerTokens.swift
    ├── LeafEmptyStateTokens.swift
    ├── LeafSectionTokens.swift
    ├── LeafToolbarTokens.swift
    ├── LeafTabTokens.swift
    ├── LeafProgressTokens.swift
    └── LeafMetricTokens.swift
```

### Usage in SwiftUI

```swift
HStack(spacing: LeafSpace.md) {
    Image(systemName: "leaf.fill")
        .foregroundStyle(LeafColor.accent.primary)
    Text("Focus session")
        .font(LeafType.title.medium)
        .foregroundStyle(LeafColor.text.primary)
}
.padding(LeafSpace.lg)
.background(LeafColor.surface.glass.glassBackground(LeafGlass.regular))
.clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg))
.shadow(LeafElevation.raised)
.animation(LeafMotion.spring.gentle, value: state)
```

### Token discipline guard

`scripts/check-tokens.sh` (запускается через `just check-tokens` + pre-commit hook):

- `grep -rE "Color\(red:|Color\(\.|#[0-9A-F]{6}" Leaf/Views/Tokens/ Leaf/Theme/` → fail если raw colors.
- `grep -rE "\.padding\([0-9]+\)" Leaf/Views/Tokens/ Leaf/Theme/Composites/` → fail если raw padding number.
- В D1 guard покрывает только `Leaf/Theme/` + `Leaf/Views/Tokens/`. В D2/D3/D4 каждая phase расширяет coverage на свои views.

## Concrete token values

### Primitive scales (T1, internal)

**Fresh leaf green** (anchor 500):

```
green.50  #F0FDF4    green.500 #22C55E ← anchor    green.800 #166534
green.100 #DCFCE7    green.600 #16A34A             green.900 #14532D
green.200 #BBF7D0    green.700 #15803D             green.950 #052E16
green.300 #86EFAC
green.400 #4ADE80
```

**Warm-neutral gray** (light surfaces, off-white):

```
gray.50   #FAFAF9   gray.500  #78716C   gray.900  #1C1917
gray.100  #F5F5F4   gray.600  #57534E   gray.950  #0C0A09
gray.200  #E7E5E4   gray.700  #44403C
gray.300  #D6D3D1   gray.800  #292524
gray.400  #A8A29E
```

**Cool charcoal** (dark surfaces, neutral):

```
slate.950 #0A0A0B   slate.700 #2A2A30   slate.300 #A0A0AB
slate.900 #131316   slate.600 #3F3F47   slate.200 #C8C8D0
slate.800 #1D1D22   slate.500 #595962   slate.50  #F4F4F7
                    slate.400 #7E7E89
```

**Status accents** (тон-shifted в semantic):

```
amber.500 #F59E0B   red.500 #EF4444    blue.500 #3B82F6
amber.600 #D97706   red.600 #DC2626    blue.600 #2563EB
```

### Semantic — Light mode (T2)

| Token | Value |
|---|---|
| `surface.canvas` | gray.50 `#FAFAF9` |
| `surface.raised` | gray.100 `#F5F5F4` |
| `surface.glass` | macOS material + accent tint 4% |
| `surface.inset` | gray.200 `#E7E5E4` |
| `text.primary` | gray.950 `#0C0A09` |
| `text.secondary` | gray.700 `#44403C` |
| `text.tertiary` | gray.500 `#78716C` |
| `text.quaternary` | gray.400 `#A8A29E` |
| `text.inverse` | gray.50 `#FAFAF9` |
| `accent.primary` | green.500 `#22C55E` |
| `accent.subtle` | green.100 `#DCFCE7` |
| `accent.emphasis` | green.600 `#16A34A` |
| `status.success` | green.600 `#16A34A` |
| `status.warning` | amber.600 `#D97706` |
| `status.danger` | red.600 `#DC2626` |
| `status.info` | blue.600 `#2563EB` |
| `border.subtle` | gray.200 `#E7E5E4` |
| `border.strong` | gray.300 `#D6D3D1` |
| `border.focus` | green.500 `#22C55E` |

### Semantic — Dark mode (T2)

| Token | Value |
|---|---|
| `surface.canvas` | slate.950 `#0A0A0B` |
| `surface.raised` | slate.900 `#131316` |
| `surface.glass` | macOS dark material + accent tint 6% |
| `surface.inset` | slate.800 `#1D1D22` |
| `text.primary` | slate.50 `#F4F4F7` |
| `text.secondary` | slate.300 `#A0A0AB` |
| `text.tertiary` | slate.400 `#7E7E89` |
| `text.quaternary` | slate.500 `#595962` |
| `text.inverse` | slate.950 `#0A0A0B` |
| `accent.primary` | green.400 `#4ADE80` |
| `accent.subtle` | green.900 @ 35% opacity |
| `accent.emphasis` | green.300 `#86EFAC` |
| `status.success` | green.400 `#4ADE80` |
| `status.warning` | amber.500 `#F59E0B` |
| `status.danger` | red.500 `#EF4444` |
| `status.info` | blue.500 `#3B82F6` |
| `border.subtle` | slate.800 `#1D1D22` |
| `border.strong` | slate.700 `#2A2A30` |
| `border.focus` | green.400 `#4ADE80` |

### Typography (LeafType, T2)

| Token | Font | Size | Weight | Tracking | Где |
|---|---|---|---|---|---|
| `display.large` | SF Pro Display | 64 | semibold | -0.02em | hero numbers |
| `display.regular` | SF Pro Display | 48 | semibold | -0.02em | section heroes |
| `title.large` | SF Pro Display | 28 | semibold | -0.01em | page titles |
| `title.medium` | SF Pro Display | 22 | semibold | 0 | section titles |
| `title.small` | SF Pro Text | 17 | semibold | 0 | card titles |
| `body.large` | SF Pro Text | 17 | regular | 0 | primary text |
| `body.regular` | SF Pro Text | 15 | regular | 0 | default body |
| `body.small` | SF Pro Text | 13 | regular | 0 | secondary body |
| `caption` | SF Pro Text | 12 | regular | 0 | timestamps, hints |
| `label` | SF Pro Text | 11 | medium | 0.04em uppercase | section labels |
| `mono.regular` | SF Mono | 14 | regular | 0 | IDs, paths |
| `mono.small` | SF Mono | 12 | regular | 0 | mono captions |

### Spacing (LeafSpace, T2, 4pt baseline)

```
xxs  2     md  12     xxl  32      4xl  64
xs   4     lg  16     3xl  48      5xl  96
sm   8     xl  24
```

### Radii (LeafRadius, T2)

```
sm    6     xl   20     pill   999
md   10    2xl   28     window native (macOS 26 auto)
lg   14
```

### Elevation (LeafElevation, T2)

| Token | y | blur | opacity (light) | opacity (dark) |
|---|---|---|---|---|
| `flat` | 0 | 0 | 0 | 0 |
| `raised` | 1 | 3 | 0.04 | 0.50 |
| `floating` | 4 | 12 | 0.08 | 0.60 |
| `modal` | 24 | 48 | 0.18 | 0.70 |

### Glass (LeafGlass, T2)

| Token | macOS 26 | macOS 14/15 fallback |
|---|---|---|
| `thin` | `.glassEffect(.regular).opacity(0.5)` | `.ultraThinMaterial` |
| `regular` | `.glassEffect(.regular)` | `.regularMaterial` |
| `thick` | `.glassEffect(.thick)` | `.thickMaterial` |
| `accentTinted` | `.glassEffect(.regular).tint(accent.primary @ 8%)` | `.regularMaterial` + accent overlay |

### Motion (LeafMotion, T2)

```
duration.snap     0.12s   button feedback, hover
duration.short    0.20s   tooltip, badge appear
duration.medium   0.35s   sheet, navigation transition
duration.long     0.55s   hero transitions, modal

spring.snappy   .interactiveSpring(response: 0.20, dampingFraction: 0.85)
spring.gentle   .interactiveSpring(response: 0.45, dampingFraction: 0.80)
spring.bouncy   .bouncy(duration: 0.50, extraBounce: 0.10)   ← редко

easing.standard    timingCurve(0.25, 0.10, 0.25, 1.00)
easing.emphasized  timingCurve(0.20, 0.00, 0.00, 1.00)

reduceMotion → все springs/easings → .linear(duration: 0)
```

## Atomic inventory (что строим в D1)

### Atoms (T2 хватает, T3 не нужен)

| # | Component | Variants |
|---|---|---|
| A1 | `LeafIcon` | size: sm/md/lg + tint via T2 |
| A2 | `LeafDot` | accent / status / muted (для presence indicator, provider dot) |
| A3 | `LeafDivider` | hairline / soft |
| A4 | `LeafSpacer` | semantic wrapper над `Spacer` |

### Molecules (T3 tokens)

| # | Component | T3 file | Variants |
|---|---|---|---|
| M1 | `LeafButton` | `LeafButtonTokens` | primary / secondary / ghost / destructive · sm/md/lg · with/without icon · loading state |
| M2 | `LeafIconButton` | `LeafIconButtonTokens` (часть `LeafButtonTokens`) | ghost / filled · sm/md/lg |
| M3 | `LeafPill` | `LeafPillTokens` | neutral / accent / success / warning / danger · with/without dot · with/without icon |
| M4 | `LeafBadge` | `LeafBadgeTokens` | neutral / accent / numeric counter |
| M5 | `LeafToggle` | `LeafToggleTokens` | off / on + disabled |
| M6 | `LeafInput` | `LeafInputTokens` | rest / focus / error / disabled · with/without prefix-icon |
| M7 | `LeafSelect` | `LeafSelectTokens` | dropdown · combobox · segmented |
| M8 | `LeafAvatar` | `LeafAvatarTokens` | initials / image · sm/md/lg · with status ring |
| M9 | `LeafIconLabel` | n/a | icon + text горизонтально · 3 alignment options |
| M10 | `LeafKeyboardShortcut` | n/a | `⌘⌥T` style hint badge |

### Organisms (T3 tokens, композят molecules)

| # | Component | T3 file | Что делает |
|---|---|---|---|
| O1 | `LeafCard` | `LeafCardTokens` | rest / raised / glass · with/without header / footer / padding presets |
| O2 | `LeafSection` | `LeafSectionTokens` | title + optional description + content slot + optional CTA в углу |
| O3 | `LeafNavRow` | `LeafNavRowTokens` | rest / hover / selected · с icon + label + optional badge + optional shortcut |
| O4 | `LeafListRow` | `LeafListRowTokens` | rest / hover / selected · primary text + secondary text + leading slot + trailing slot |
| O5 | `LeafStatusPill` | `LeafStatusPillTokens` | idle / active / sharing / invisible · animated dot |
| O6 | `LeafBanner` | `LeafBannerTokens` | info / success / warning / danger · с icon + title + description + CTA + dismiss |
| O7 | `LeafEmptyState` | `LeafEmptyStateTokens` | icon (SF Symbol крупный) + title + description + optional CTA — **никаких mascot illustrations** |
| O8 | `LeafToolbar` | `LeafToolbarTokens` | leading / center / trailing slots с правильными paddings |
| O9 | `LeafTab` | `LeafTabTokens` | inline tab nav (для sub-sections внутри page, не главный sidebar) |
| O10 | `LeafProgress` | `LeafProgressTokens` | linear / circular · determinate / indeterminate |

### Metric primitives (отдельная категория — anti-SaaS-dashboard discipline)

| # | Component | Что делает | Anti-pattern guard |
|---|---|---|---|
| MT1 | `LeafMetricInline` | число внутри текстового narrative — `Text("Сегодня focus: ") + Text("4h 32m").metric()` | используется когда метрика часть фразы |
| MT2 | `LeafMetricAmbient` | большое тихое число + label, без card-shadow, без trending arrow | используется когда метрика — главный элемент section'а (одна на всю section) |
| MT3 | `LeafMetricDelta` | число + дельта (↑/↓ + value) **только если** дельта реально читается контекстом | НЕ дефолт, осознанный выбор |
| MT4 | `LeafSparkline` | тонкий sparkline без axis/labels — только trend shape | используется внутри LeafCard или LeafListRow, не stand-alone |

**Правило для D2/D3/D4:** на странице **максимум один** `LeafMetricAmbient` per section. Если нужно показать 4 числа — это **НЕ four cards**, это либо list rows с inline metrics, либо composed Section с другим principle.

### Templates (layout shells)

| # | Component | Что делает |
|---|---|---|
| T1 | `LeafWindowLayout` | NavigationSplitView wrapper с правильными paddings и safe areas |
| T2 | `LeafSheetLayout` | sheet wrapper с правильным dismissal + glass background |
| T3 | `LeafMenuBarLayout` | popover wrapper — компактный, fixed-width, для menubar dropdown |
| T4 | `LeafOnboardingStepLayout` | full-bleed step layout (centered content + nav buttons + progress) |

**Итого: 28 элементов** (4 atoms + 10 molecules + 10 organisms + 4 metric primitives + 4 templates).

## Reference screen (Tokens Preview)

**Где живёт:** `Leaf/Views/Tokens/TokensPreviewScreen.swift` + sub-views в той же папке.

**Доступ:**
- Debug-only (`#if DEBUG`).
- Открывается через menu shortcut `⌘⌥T` (новый `CommandGroup` в `LeafApp.swift`).
- В release builds меню-айтем не появляется, но файлы компилятся для тестов.

**Sections (top-to-bottom scroll):**

1. **Color** — surface / text / accent / status / border swatches с values.
2. **Typography** — все 12 styles, sample text + spec в углу.
3. **Spacing / Radii / Elevation** — visual ladder для каждого scale.
4. **Glass** — thin / regular / thick / accentTinted samples + side-by-side macOS 26 vs macOS 14 fallback note.
5. **Motion** — live demos (button press, card hover, sheet appear), spring comparisons, reduceMotion toggle.
6. **Atoms** A1..A4 — все variants.
7. **Molecules** M1..M10 — все variants и states (rest / hover / focus / pressed / disabled).
8. **Organisms** O1..O10 — все variants.
9. **Metrics** MT1..MT4 — с примером narrative для inline.
10. **Templates** T1..T4 — превью layout shells (миниатюрная версия каждого).

**Ключевые фичи самого экрана:**

1. **Appearance switcher в углу** — Light / Dark / Auto override прямо на экране, не дёргая system settings.
2. **Reduce-motion toggle** — отдельный switch чтобы проверить motion fallback.
3. **macOS version banner** — top-right показывает "macOS 26 polish" или "macOS 14 fallback" (детектится через `if #available`). На macOS 26 в Glass-секции есть кнопка "force fallback preview" которая force-degrades только в этом превью для side-by-side сравнения.
4. **Каждый компонент с inline spec** — снизу серым текстом `LeafButton.Primary · md · LeafSpace.lg · LeafRadius.md`. Плюс кнопка "Copy code snippet" → копирует declarative usage в clipboard.
5. **Hover/focus/press demos** для states — рядом с компонентом две версии: "rest" и "interact me" (вторая реальная, можно навести).

**Acceptance:**
- Все 28 элементов рендерятся без warnings.
- Light + Dark + Auto переключатель работает.
- macOS 26 polish и macOS 14 fallback оба валидны (smoke на двух версиях).
- Reduce-motion fallback корректный.

## macOS 26 vs 14/15 fallback story

**Минимальный таргет — `macOS 14`** (текущий в `Package.swift`, не меняем).

**Strategy — graceful enhancement, не graceful degradation:**

| API | macOS 14/15 path | macOS 26 path |
|---|---|---|
| Glass surfaces | `Material.regularMaterial` etc через `LeafGlass.*` wrapper | `.glassEffect(...)` + `GlassEffectContainer` для морфинга |
| Sheets | `.sheet(...)` стандартный | `.sheet(...)` + automatic glass background |
| Buttons | `.bordered` / `.borderedProminent` через `LeafButton` | `.glass` / `.glassProminent` через тот же `LeafButton` |
| Animations | spring/timing API одинаковые с iOS 17+ | то же + `@Animatable` macro для custom (НЕ в D1) |
| Tinting | `.tint(LeafColor.accent.primary)` | то же |

**Pattern везде:** один SwiftUI struct (`LeafButton`, `LeafCard`...) внутри которого `if #available(macOS 26, *) { ... } else { ... }`. Внешний API один, фолбэк прозрачен.

**Tokens Preview screen рендерится одинаково** на обеих версиях, но в Glass-секции есть baseline-плашка "macOS 14 fallback render". На 26 есть toggle "force-fallback-preview" чтобы видеть как будет выглядеть на 14 *с этой машины*.

**Существующий `Theme/GlassModifiers.swift`** (`LeafGlassGroup`, `LeafProminentButton`, `LeafSecondaryButton`) уже правильной формы. D1 их **переиспользует** — `LeafButton` внутри собирает `LeafProminentButton` / `LeafSecondaryButton` как backend, добавляя token-aware sizing и Tier 3 layer.

## Migration approach — Snapshot Replacement

**Правило:** D1 ships язык, **существующие views не трогает**.

1. `Theme/Colors.swift` (старый, `BrandCream` etc) остаётся. Не удаляется. Не трогается.
2. `Theme/GlassModifiers.swift` остаётся, переиспользуется внутри новых composites.
3. Asset Catalog получает **новые color sets** рядом со старыми. `BrandCream` остаётся (light only), `leaf.surface.canvas` (new) добавляется (light + dark).
4. Существующие views (`HomeView`, `RootView`, `Sidebar`, `MenuBarContent`, etc) продолжают использовать `Color.leafBackground` etc. Не трогаются в D1.
5. Pre-commit guard включается **только для путей `Leaf/Theme/` и `Leaf/Views/Tokens/`** в D1. Для остальных view-папок guard добавляется в каждой phase D2/D3/D4 по мере миграции той папки.
6. Tokens Preview screen использует **только новые tokens**. Не использует старые `BrandCream` etc.

**Когда old palette окончательно удаляется:** после ship D4 (т.е. когда последний view мигрирован). До этого — оба сосуществуют, явно сегрегированы по папкам.

**Token deprecation policy** (для будущего, не для D1): Tier 2 token нельзя ломать без alias на 1 release.

## Open questions / risks

- **macOS 14 testing matrix.** Нужна VM или старый Mac на 14.x для smoke. У Alex есть macOS 26 dev, у Саши — TBD. Если нет 14.x — Tokens Preview всё равно компилируется, но manual smoke на 14 пропадает. Acceptance criteria #4 требует обе версии — risk если 14 машина недоступна.
- **macOS 26 polish baseline.** Adoption macOS 26 на 2026-05 ~50%. Половина юзеров увидит fallback. Дисциплина "fallback должен выглядеть достойно" критична — нельзя проектировать только под Liquid Glass и забивать на bordered.
- **"Force fallback preview" реализация.** На macOS 26 force-degradation `if #available` нельзя обмануть прямо. Нужен EnvironmentKey `forceLegacyGlass` который Tokens Preview переключает. Все glass wrappers читают этот key и игнорируют availability check если он `true`. Это complexity, но без него side-by-side сравнение невозможно.
- **Asset Catalog naming.** Apple's color set naming не любит точки в именах (`leaf.surface.canvas` → реально `leaf-surface-canvas` или `leafSurfaceCanvas` в .xcassets). В Swift wrapper маппим красивое имя на реальное. Не блокер, мелкая инфраструктура.
- **Pre-commit guard как enforce.** `lefthook` не настроен в проекте, есть только manual `just`-recipes. Решение D1: добавляем `just check-tokens` recipe + опционально CI step. Реальный pre-commit hook — отдельный D-1.5 если захочется.

## Out-of-scope для D1 (carry-over в D2/D3/D4)

- Перерисовка screens — D2 (Home + Sidebar) → D3 (Activity + Team + Connections) → D4 (Onboarding + Org + Settings + MenuBar + sheets).
- Charts wrappers — D2 при дизайне Home или признаём что system Swift Charts хватает.
- Brand mark / logo redesign — отдельный track.
- Animation библиотека для custom (`@Animatable` macro) — postponed, на ровном месте не нужна.
- Localization (внутри tokens) — все label-style tokens предполагают latin, кириллица влезает; arabic / hebrew RTL — отдельный track.

## Glossary

- **Atomic design** — Brad Frost methodology: atoms → molecules → organisms → templates → pages.
- **Tier 1 / 2 / 3 tokens** — primitive (raw) / semantic (intent) / component (component-specific).
- **Liquid Glass** — Apple's iOS 26 / macOS 26 dynamic glass material (refraction, morphing, depth).
- **Snapshot Replacement migration** — D1 ships token system без переезда existing views; D2/D3/D4 мигрируют свои views постепенно.
- **Tokens Preview** — debug-only storybook screen за `⌘⌥T`, показывает все компоненты live.
