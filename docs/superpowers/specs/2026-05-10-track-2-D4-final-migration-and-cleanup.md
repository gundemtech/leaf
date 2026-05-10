# Track 2 — D4: Final Migration & Cleanup

**Date:** 2026-05-10
**Author:** Dmitrii (with Claude, autonomous-decision mode)
**Status:** spec for review
**Track:** 2 (UI/UX redesign of Native Leaf macOS app)
**Phase:** D4 of 4 (D1 = Foundation [landed], D2 = Navigation Shell + Home [landed], D3 = Data Surfaces [landed], D4 = Final Migration & Cleanup)
**Stacked on:** `feature/track-2-D3-data-surfaces` (D3 не merged в `main`; Track 2 merges коллективно после D4 acceptance gate)
**Branch:** `feature/track-2-D4-final-migration-and-cleanup`

## TL;DR

D3 переписал Activity / Team / Connections — последние data-heavy screens. **D4 закрывает Track 2** — мигрирует остальные production views на D1 substrate (sheets / Organization / Settings / Profile / Onboarding / MenuBar / RemovedFromTeamBanner / ShareTemplateButton + 2 token previews), **retire'ит** старую палитру (`Leaf/Theme/{Colors,Fonts,GlassModifiers,CategoryColors}.swift`) и старые wrapper-helper'ы (`Window/Shared/{GlassCard,EmptyStateView,MetricCard}.swift`, `Views/BannerView.swift`), и финализирует token-discipline guard третьим RETIRED-tier'ом.

Архитектурные акценты:

- **Sheets (3) — adopt `LeafSheetLayout` template.** GenerateInviteSheet / AcceptInviteSheet / RemoveMemberSheet переезжают с ad-hoc VStack-padding-frame на `LeafSheetLayout(title:, onDismiss:)`. Заменяют GlassCard на LeafCard.raised; success/error states на LeafBanner; вёрстка унифицируется через LeafSection blocks.
- **Window screens (4) — drop `Form` chrome, adopt LeafSection chain.** OrganizationView / WindowSettingsView (+ GeneralSettingsSection / PrivacySettingsSection / FoldersSettings) / ProfileView / RemovedFromTeamBanner переезжают на LeafSection + LeafCard. ProfileView stats — LeafMetricCard. RemovedFromTeamBanner — LeafEmptyState (hero icon + title + description, info-only — wipe action остаётся out-of-MVP).
- **MenuBar + Onboarding — special-case migration без template.** MenuBarContent normalBody переезжает на LeafMenuBarLayout (T3 template, 360pt width); BannerView (single consumer = MenuBarContent) удаляется, заменяется LeafBanner inline. OnboardingView + 3 step views — inline migration на D1 atoms (LeafButton/LeafType/LeafColor/LeafSpace/LeafIcons), **не** LeafOnboardingStepLayout — popover constraint (320pt width, MenuBarExtra contentSize).
- **Retirement.** После migration consumer'ов — hard delete файлов старой палитры + старых wrappers. Compile-time guard (`-Onone` build fails on dangling refs) — primary; check-tokens RETIRED tier — secondary defense-in-depth.

**Locale:** English (D2/D3 precedent). UI strings — English; русский только для commit messages / spec / code comments.

## Vision recap (Track 2 closure)

D1 заложил substrate. D2 переписал shell + Home. D3 переписал Activity / Team / Connections. **D4 закрывает Track 2 на полном production sweep.** После D4:

- **Zero old-palette compiles** — `Color.leafInk` / `Font.leafBody` / `.leafLabelStyle()` / `GlassCard` / `MetricCard` / `EmptyStateView` (Window/Shared) / `LeafProminentButton` / `LeafSecondaryButton` / `LeafGlassGroup` / `Color.leafCategory(_:)` буквально не compile (token + helper files удалены).
- **Zero non-tokenised UI** — каждая production-view линия проходит token-discipline guard в полной MIGRATION зоне.
- **Defense-in-depth** — RETIRED tier check-tokens.sh ловит accidental re-introduction via comment-quote или copy-paste из git history.
- **Snapshot Replacement** complete — все production screens на одном дизайн-языке, единый visual rhythm: typography (LeafType) / spacing (LeafSpace) / color (LeafColor) / radius (LeafRadius) / elevation (LeafElevation) / glass material (LeafGlass) / motion (LeafMotion).

Принципы D1 carry over без exceptions:

- **Color is a signal, not a wash.** Settings Status row Circle (red/orange/gray статус LaunchAgent) keep — это semantic signal, не decoration. ProfileView avatar overlay-stroke (старая palette `Color.leafAccent.opacity(0.3)`) — drop, LeafAvatar `LeafColor.surface.inset` Circle background carry'ит identity.
- **Numbers are quiet.** LeafMetricCard в ProfileView — drop `caption` parameter (D1 substrate не surface'ит caption — title carries unit semantics, e.g. "Active streak / 5 days"). Single-line Profile fold preserved.
- **Glass as a quiet material.** Sheets adopt `LeafSheetLayout` (glass background). Settings tabs / Organization / Profile — `LeafCard.raised` (neutral elevated surface). MenuBar popover — `LeafMenuBarLayout` (`LeafColor.surface.raised` background, без glass — popover material handled by MenuBarExtra system chrome).
- **Motion is information.** D4 не добавляет новых transitions. Onboarding step transitions preserve current `.onChange` driven step advance (no `.transition(...)` wrappers — substrate анимация только LeafButton hover + LeafTab matchedGeometry).

## Anti-patterns (won't-list для D4)

- ❌ **Native `Form(formStyle: .grouped)` chrome.** WindowSettingsView + 3 sub-sections + FoldersSettings — drop. Replace each Section with LeafSection block. `formStyle(.grouped)` macOS-system look не aligns с unified design language. Settings tab — часть unified product surface, не отдельный Settings scene.
- ❌ **Ad-hoc sheet `.padding(28).frame(width: 560, height: 600)`.** Drop. LeafSheetLayout owns padding (`LeafSpace.xl` outer) + min frame (`LeafSheetLayoutTokens.minWidth/minHeight`). Sheet sizes к content (system natural sizing) без forced .frame override.
- ❌ **Section header / footer Text-pair.** `Text("SETTINGS").leafLabelStyle() + Text("Settings").font(.leafHeadline)` pattern везде. LeafSection (T2 token-driven) carries title + optional description natively. Drop manual chrome.
- ❌ **Old wrapper helpers** (GlassCard / EmptyStateView / MetricCard / BannerView / LeafProminentButton / LeafSecondaryButton / LeafGlassGroup / `Color.leafCategory(_:)`). All retired — D1 substrate covers all use-cases.
- ❌ **Backwards-compat shims for old palette.** No `@available(*, deprecated)` stubs. CLAUDE.md root rule "Avoid backwards-compatibility hacks" — hard delete files после verifying zero consumers grep'ом.
- ❌ **Forced template adoption where constraints clash.** OnboardingView lives inside `MenuBarExtra(...).menuBarExtraStyle(.window)` popover, sized `.frame(width: 320)`. LeafOnboardingStepLayout — full-bleed template `.frame(maxWidth: .infinity, maxHeight: .infinity)` + Spacer()-Spacer()-content vertical centering. Spacer() в MenuBarExtra-popover (no external maxHeight constraint) → ambiguous layout. **Don't force.** Migrate Onboarding views inline to D1 atoms; keep current popover frame. LeafOnboardingStepLayout остаётся в substrate library для v1.1 architectural change to full-window onboarding.
- ❌ **Stock illustrations / animated mascots / skeleton shimmer** — D1 §29 + D3 carry-over. RemovedFromTeamBanner adopts LeafEmptyState pattern (hero icon + title + description) — no decorative animation.
- ❌ **Multiple sources of truth для старой палитры.** D2/D3 left `Leaf/Theme/{Colors,Fonts}.swift` + `Window/Shared/{GlassCard,EmptyStateView,MetricCard}.swift` available for non-migrated views. After D4 — все consumers migrated, files **deleted** (not stubbed). Compilation enforces zero residual refs.

## Scope

### В D4

| Файл | Action |
|---|---|
| `Leaf/Views/Window/Team/GenerateInviteSheet.swift` | full rewrite — adopt LeafSheetLayout + LeafCard.raised + LeafBanner inline; drop GlassCard / `.leafLabelStyle()` / `Font.leaf*` refs |
| `Leaf/Views/Window/Team/RemoveMemberSheet.swift` | full rewrite — adopt LeafSheetLayout + LeafCard.raised; success → LeafCard with leading LeafIcon (status.success); error → LeafBanner.danger inline |
| `Leaf/Views/Window/Organization/AcceptInviteSheet.swift` | full rewrite — adopt LeafSheetLayout + LeafCard.raised + LeafBanner inline; preserve 3-input-paths state machine + scenePhase clipboard auto-fetch (5.5.B contract) |
| `Leaf/Views/Window/Organization/OrganizationView.swift` | full rewrite — LeafSection blocks for `.empty` (create CTA + or-join-team divider) и `.loaded` (workspace card); LeafBanner.danger для `.error` |
| `Leaf/Views/Window/Settings/WindowSettingsView.swift` | full rewrite — drop manual section header chrome; pure VStack of LeafSection-rendering sub-sections |
| `Leaf/Views/Window/Settings/GeneralSettingsSection.swift` | full rewrite — drop Form/Section chrome; LeafSection (title="Background collection") + LeafCard with LeafToggle, status row (LeafListRow с leading LeafDot + trailing label), error inline + LeafButton.secondary "Refresh status"; LeafSection (title="Updates") + LeafCard with version row + LeafButton.secondary "Check for Updates…" |
| `Leaf/Views/Window/Settings/PrivacySettingsSection.swift` | full rewrite — LeafSection (title="Privacy", description=footer-copy-folded-up) + LeafCard with informational text |
| `Leaf/Views/FoldersSettings.swift` | full rewrite — drop Form chrome; LeafSection (title="Watched folders", description=info-text-folded-up, cta=LeafButton.secondary "Add…") + LeafCard wrapping list of LeafListRows; per-row trailing slot = Picker + LeafToggle + LeafIconButton(asset: trash) |
| `Leaf/Views/Window/Profile/ProfileView.swift` | full rewrite — LeafAvatar (size: .lg, drop overlay stroke); LeafSection-less header (info row only, no section title); LeafMetricCard (drop caption, title carries unit) inside LazyVGrid |
| `Leaf/Views/RemovedFromTeamBanner.swift` | full rewrite — LeafEmptyState (icon: object.userError, title carrying orgName, description carrying current copy); preserve full-screen takeover behavior (RootView preempts via shell); replace `Color.leafBackground.ignoresSafeArea()` with `LeafColor.surface.canvas` |
| `Leaf/Views/MenuBarContent.swift` | full rewrite — adopt LeafMenuBarLayout (360pt width); LeafBanner inline для agent-off / AX / FDA banners (replace BannerView callsites); LeafButton.primary "Open" (replace LeafProminentButton); ad-hoc hero (FOCUS TODAY) → LeafKPI-style composition (LeafType.label uppercase + LeafType.title.large display number); top-apps list — LeafListRow chain inside LeafCard.rest |
| `Leaf/Views/OnboardingView.swift` | full rewrite — inline composition (NOT LeafOnboardingStepLayout); preserve all state machine logic (.onChange / .sheet / .onAppear permission polling); migrate to D1 atoms (LeafType / LeafButton / LeafColor / LeafSpace / LeafIcons) |
| `Leaf/Views/Onboarding/CreateTeamStepView.swift` | internal rewrite (interface preserved: `init(onCancel: () -> Void)`) — D1 atoms migration |
| `Leaf/Views/Onboarding/JoinTeamStepView.swift` | internal rewrite (interface preserved: `init(onAdvance:, onCancel:)`) — D1 atoms migration; preserve JoinCode load + ShareTemplateButton wiring |
| `Leaf/Views/Onboarding/WaitingForInviteView.swift` | internal rewrite (interface preserved: `init(onManualPaste:, onCancel:)`) — D1 atoms migration |
| `Leaf/Views/Common/ShareTemplateButton.swift` | internal rewrite (interface preserved: `init(templateBody:, mailSubject:, onCopy:)`) — replace .borderedProminent / .bordered system buttons with LeafButton primary / 2× secondary; LeafIcons asset references preserved (already on tokens) |
| `Leaf/Views/Tokens/Components/LeafSheetLayoutPreview.swift` | small edit — replace `LeafProminentButton` / `LeafSecondaryButton` with `LeafButton(_, variant: .primary, …)` / `LeafButton(_, variant: .secondary, …)` (token preview must use D1 substrate, not retired wrappers) |
| `Leaf/Views/Tokens/Components/LeafOnboardingStepLayoutPreview.swift` | small edit — same LeafButton substitution |
| `scripts/check-tokens.sh` | extend MIGRATION_PATHS to entire `Leaf/Views/` (minus `Leaf/Views/Tokens/` BASE); add **RETIRED tier** banning old-palette names everywhere в `Leaf/` |
| `scripts/tests/test-check-tokens.sh` | extend self-test fixtures — D4 MIGRATION whole-Views/ + RETIRED tier (clean-passes, old-palette-fails в любом scope) |

### Deletions (D4)

| Файл | Reason |
|---|---|
| `Leaf/Theme/Colors.swift` | old palette static Color extensions + ShapeStyle conformance — zero consumers after D4 |
| `Leaf/Theme/Fonts.swift` | old palette Font extensions + `.leafLabelStyle()` extension — zero consumers after D4; `leafSectionLabel()` (D1) replaces |
| `Leaf/Theme/GlassModifiers.swift` | LeafProminentButton / LeafSecondaryButton / LeafGlassGroup wrappers — zero consumers after token-preview migration; `LeafButton` + `LeafGlass.*` token replace |
| `Leaf/Theme/CategoryColors.swift` | `Color.leafCategory(_:)` — zero consumers after D3 (SessionRow dropped category dot per D3 OQ-6) |
| `Leaf/Views/Window/Shared/GlassCard.swift` | wrapper component — zero consumers after Org/Sheets/Profile/MetricCard migration; `LeafCard.raised` / `LeafCard.glass` replace |
| `Leaf/Views/Window/Shared/EmptyStateView.swift` | already orphaned (zero consumers — verified grep) — relic from earlier "team coming soon" placeholder |
| `Leaf/Views/Window/Shared/MetricCard.swift` | wrapper component — zero consumers after Profile migration; `LeafMetricCard` replaces |
| `Leaf/Views/BannerView.swift` | wrapper component — zero consumers after MenuBarContent migration; `LeafBanner` replaces |
| `Leaf/Views/Window/Shared/` (directory) | empty after 3 file deletes — `git rm -r` |

### Comments / docstrings refresh

| File | Change |
|---|---|
| `Leaf/Theme/Tokens/LeafType.swift` | `Text.leafSectionLabel()` doc-comment refers to "legacy `leafLabelStyle` в `Leaf/Theme/Fonts.swift` (Snapshot Replacement migration — old palette stays until D4 ships)". After D4 — update comment to drop legacy reference + Snapshot Replacement note (Snapshot Replacement complete). |

### НЕ в D4 (явно)

- **D2/D3 production views** — RootView / Sidebar / Home / Activity / Team (TeamView, PendingInvitesSection, PendingInviteRow) / Connections — D2/D3-migrated, **не трогаются** в D4. Single exception: D4 must NOT regress D2/D3 token-discipline (RETIRED tier inherits MIGRATION = whole Views/ — D2/D3 paths automatically still under guard).
- **D1 substrate code** — `Leaf/Theme/{Tokens,Composites,Layouts,Primitives}/**` + `Leaf/Theme/AvailabilityShims.swift` — preserved. Single additive change: `LeafType.swift` doc-comment refresh.
- **`LeafApp.swift`** — preserved entirely (scenes, OpenSettingsCommand, OpenTokensPreviewCommand, .onOpenURL, .onAppear permissions wire-up, .onChange scenePhase clipboard probe).
- **TokensPreview screen + sections** — preserved per D1/D2/D3 acceptance carry-over (`⌘⌥T` still works). Two preview files within `Leaf/Views/Tokens/Components/` мигрируют от LeafProminentButton/LeafSecondaryButton к LeafButton; otherwise `Leaf/Views/Tokens/**` untouched.
- **Service / Reader contracts** — D4 — pure UI substrate. Использует existing surfaces (`InsightsReader` / `OrgReader` / `LaunchAgentService` / `WatchedFoldersService` / `UpdaterController` / `PermissionsService` / `InviteOutboxReader` / `InviteAcceptReader` / `MemberRemovalReader` / `InviteURLHandler` / `IdentityService` / `WindowState`) без модификации contracts.
- **Phase 5.4 surfaces** (presence broadcast, presence_outgoing / presence_history rendering, Share Controls UI, blocklist editor) — out per Track 2 charter (UI/UX redesign of existing surfaces only).
- **In-app AI / BYOK setup screens** — out per architecture doc (no LLM dependencies в MVP).
- **Settings new sections** (e.g. "Updates channel" picker, "Storage" stats, "Right to deletion" CTA) — D4 не добавляет content beyond migration.
- **AcceptInviteSheet `.frame(width: 560, height: 600)` strict-preservation** — out. After LeafSheetLayout adoption, sheet sizes к content + minWidth/minHeight tokens. Width may shift slightly (smaller на successCard, similar на otpEntry); acceptable per Snapshot Replacement.
- **OnboardingView architectural lift** (move from MenuBarExtra popover to standalone Window scene) — out. Architectural change beyond UI migration; preserves popover-style onboarding per LeafApp.swift contract.
- **D4 `LeafCard.glass` adoption inside sheets** — out. Sheet template (`LeafSheetLayout`) wraps content with `.leafGlass(.regular, ...)` at template level; inner cards stay `LeafCard.raised` (neutral surface inside glass shell). Glass-on-glass anti-pattern.

### Acceptance criteria

1. `⌘⌥T` Tokens Preview всё ещё открывается (D1+D2+D3 baseline preserved); both `LeafSheetLayoutPreview` и `LeafOnboardingStepLayoutPreview` render с LeafButton (no LeafProminentButton / LeafSecondaryButton refs).
2. **Sheets — LeafSheetLayout adopted (3/3).** GenerateInviteSheet (title="Add a team member"), AcceptInviteSheet (title="Join your team"), RemoveMemberSheet (title="Remove member") wrap content в `LeafSheetLayout(title:, onDismiss:)`. No ad-hoc `.padding(28).frame(width:, height:)` остались. Footer button-row (Discard / primary CTA) preserved as inner content's last row.
3. **Sheets — content state machines preserved (3/3).** GenerateInviteSheet 4-state (idle/generating/ready/error) + 2 inputModes (paste/template), AcceptInviteSheet 6-state (idle/fetching/otpEntry/accepting/success/error), RemoveMemberSheet 4-state (idle/removing/success/error) — each rendering correctly post-migration: state-routed `@ViewBuilder` content unchanged in shape, internals migrated to LeafCard.raised + LeafBanner + LeafButton.
4. **OrganizationView — 4 OrgReader states migrated.** `.loading` → ProgressView centered. `.empty` → LeafSection ("Organization", "Create your personal org.") + LeafCard with workspace name input + LeafButton.primary; OR-divider + LeafSection ("Or join a team") + LeafButton.secondary "Accept invite" (opens AcceptInviteSheet). `.loaded(org, _)` → LeafSection ("Organization") + LeafCard with workspace metadata. `.error` → LeafBanner.danger + retry. `.removedFromOrg` → EmptyView (RootView preempts).
5. **WindowSettingsView — 3 sub-sections migrated, no Form chrome.** Sub-sections render as LeafSection blocks: General (background collection toggle/status/error/refresh, version/check-for-updates), Folders (per-folder picker/toggle/remove + Add CTA), Privacy (info copy). Top-level header chrome dropped (each LeafSection carries own title).
6. **ProfileView — LeafAvatar + LeafMetricCard adopted.** Header: LeafAvatar (size: .lg, initials) + name + "Leaf · Local user" caption (LeafType.body.regular, text.secondary). Stats: LazyVGrid hosting 2 LeafMetricCards ("Active streak" / "5 days", "Deep work streak" / "1d 3h"); no caption parameter (folded into title). `.loading` (`.notLoaded`) state — LeafType.body.regular text.secondary message.
7. **RemovedFromTeamBanner — LeafEmptyState adopted.** Hero icon (asset `LeafIcons.object.userError`) + title (carries orgName) + description (current "Your local data remains…" copy). Background = `LeafColor.surface.canvas`. Full-screen `.frame(maxWidth: .infinity, maxHeight: .infinity)` preserved (RootView preempts via shell branch).
8. **MenuBarContent — LeafMenuBarLayout adopted (360pt width).** Hero (FOCUS TODAY label + total focus duration) renders via LeafType.label uppercase tracked + LeafType.title.large primary. Banners (agent-off / AX / FDA) render via LeafBanner inline (replacing BannerView). Top-apps list renders via LeafListRow chain inside LeafCard.rest. "Open" CTA = LeafButton.primary; "Quit" — keep system Button.borderless + LeafColor.text.secondary tint + ⌘Q shortcut.
9. **Onboarding — 4 views migrated to D1 atoms (NOT LeafOnboardingStepLayout).** OnboardingView preserves 5-step state machine (welcome / ax / fda / team / done) + .sheet(AcceptInviteSheet) + scenePhase chain. Each step view (CreateTeamStepView, JoinTeamStepView, WaitingForInviteView) inline rewritten on LeafType + LeafButton + LeafColor + LeafSpace + LeafIcons. 320pt popover frame preserved.
10. **ShareTemplateButton — LeafButton adopted (3 buttons).** Copy = LeafButton.primary (icon: .asset(LeafIcons.comm.copy)). Mail = LeafButton.secondary (icon: .asset(LeafIcons.comm.email)). Messages = LeafButton.secondary (icon: .asset(LeafIcons.comm.message)). Behavior preserved (NSPasteboard + NSWorkspace.open).
11. **Retirement — 8 files deleted + 1 directory removed.** `Leaf/Theme/{Colors,Fonts,GlassModifiers,CategoryColors}.swift` + `Leaf/Views/Window/Shared/{GlassCard,EmptyStateView,MetricCard}.swift` + `Leaf/Views/BannerView.swift` + `Leaf/Views/Window/Shared/` (empty dir) — `git rm`. `LeafType.swift` doc-comment refresh.
12. `just check-tokens` passes для всех D4-migrated files; `just check-tokens-self-test` passes (расширенный self-test покрывает MIGRATION whole-Views/ + RETIRED tier across-Leaf/).
13. 5/5 xcodebuild schemes green (Leaf / LeafAgent / LeafCore / LeafCorePrivate / LeafMCP). `LeafAgent` / `LeafCore` / `LeafCorePrivate` / `LeafMCP` не трогаются D4 — verify untouched.
14. 1213 SPM tests baseline preserved (zero new tests — D4 — pure UI substrate; runtime validate через manual smoke per AC1-13).

## Aesthetic anchors

D1 / D2 / D3 anchors carry over без изменений:

- **Apple-native** через Liquid Glass system materials (sheets — `LeafSheetLayout` glass background; MenuBar — system MenuBarExtra material).
- **Notion** — generous whitespace, content-first hierarchy, soft palette.
- **Linear** — precision, hover-state quality, monospace для IDs / hex / timestamps / version strings.

D4-specific:

- **Settings** — Notion-style block hierarchy: each LeafSection = block; LeafCard.raised inside carries form controls. No `formStyle(.grouped)` macOS-system rectangle. Section titles act as anchors.
- **Sheets** — Apple-native sheet idiom: glass background (LeafSheetLayout), title in toolbar (LeafToolbar leading slot), single primary CTA + dismiss in footer-row.
- **MenuBar** — Things-3-style compact popover: 360pt fixed width (LeafMenuBarLayoutTokens), banners ahead of content (привлекают внимание прежде чем юзер scan'ит data), `LeafButton.primary` "Open" anchor сверху bottom row.
- **Onboarding** — Mac-native first-run popover: compact 320pt, step dots ahead of content, primary CTA anchored bottom-right, Skip-link ghost-buttoned для opt-out.

## Information Architecture

### Sheets (3) — common pattern

```
Sheet body
└─ LeafSheetLayout(title: <Sheet title>, onDismiss: { dismiss + reader.discard }) {
     VStack(spacing: LeafSpace.xl) {
       content                           ← state-routed @ViewBuilder (preserved)
       Spacer(minLength: 0)
       footerButtonRow                   ← Discard / primary CTA
     }
   }
```

LeafSheetLayout owns:
- glass background (`.leafGlass(.regular, cornerRadius: LeafRadius.lg)`)
- LeafToolbar header (title + LeafIconButton.close)
- outer padding (`LeafSpace.xl`)
- min frame (`LeafSheetLayoutTokens.minWidth: 480 / minHeight: 360`)

Sheet body drops:
- `.padding(28)` (replaced by template's outer padding)
- `.frame(width: 520-560, height: 380-600)` (replaced by min-frame + content sizing)
- ad-hoc header (`Text("INVITE").leafLabelStyle() / Text("Add member").font(.leafHeadline)`) — title goes to template
- per-state `GlassCard(padding: 20-24) { ... }` wrappers — replaced by `LeafCard.raised(padding: .regular)` inner blocks

#### GenerateInviteSheet — state-by-state

`@Environment` envs preserved (InviteOutboxReader, OrgReader, InviteURLHandler, dismiss). State enum + InputMode enum preserved.

| State | Render |
|---|---|
| `.idle` / `.error` | LeafCard.raised with: LeafTab(selection: $inputMode, tabs: InputMode.allCases, label: \.rawValue) (replaces native Picker .segmented); modeContent(disabled: false). On `.error` — LeafBanner.danger inline below modeContent. |
| `.generating` | LeafCard.raised with: LeafTab disabled-state (substrate doesn't yet support disabled tab — leave selection live, but disable inner CTAs). modeContent(disabled: true) + ProgressView. |
| `.ready(outbound)` | LeafCard.raised with: LeafSection-style "SEND INVITE LINK" inline label + url textSelection-enabled mono + ShareTemplateButton + countdown caption. |

Mode content:
- `.paste` mode: LeafCard.raised inner block с paste-instructions + TextField (axis: .vertical, lineLimit 2) + LeafButton.primary "Generate invite" (right-aligned).
- `.template` mode: LeafCard.raised inner block с template-instructions + ShareTemplateButton.

Footer-row: `Discard` (LeafButton.secondary) + Spacer + `Revoke + Done` (LeafButton.primary, only on `.ready`).

#### AcceptInviteSheet — state-by-state

`@Environment` envs preserved. 6-state machine preserved.

| State | Render |
|---|---|
| `.idle` | pasteCard(disabled: false) |
| `.fetching` | pasteCard(disabled: true) + ProgressView below |
| `.otpEntry(_, attempts, _)` | otpCard(attempts:, disabled: false) |
| `.accepting` | otpCard(attempts: 0, disabled: true) + ProgressView |
| `.success(orgName, memberCount)` | LeafCard.raised with leading LeafIcon (status.successFill, status.success tint) + "Joined \(orgName)" + "Now part of N-member team" body |
| `.error(message, recoverable)` | LeafBanner.danger inline + Try-again CTA (only when recoverable) |

pasteCard: instructions + `leaf://invite/...` TextField (mono lineLimit 2) + LeafButton.primary "Use link".
otpCard: instructions + 6-digit OTP TextField (mono) + Display name TextField + attempts feedback + LeafButton.primary "Join team".

Footer-row: `Discard` (LeafButton.secondary) + Spacer + variable (Done / Close / Discard+ask-admin) per state.

#### RemoveMemberSheet — state-by-state

`@Environment` envs preserved. 4-state machine preserved.

| State | Render |
|---|---|
| `.idle` | confirmCard (LeafCard.raised with rotation-warning copy) |
| `.removing` | confirmCard + ProgressView + "Rotating team key…" |
| `.success(outcome, displayName)` | LeafCard.raised with leading LeafIcon (status.successFill, status.success tint) + "Removed \(displayName)" + outcome.peerCount summary body |
| `.error(message)` | LeafBanner.danger inline + body |

Sheet primary text "Remove \(displayName) from the team?" moves into LeafSheetLayout title? No — LeafSheetLayout title = "Remove member" (generic); subtitle/primary-question moves to first inner card row (LeafType.title.medium primary text, body below).

Footer-row: `Cancel` (LeafButton.secondary) + Spacer + state-routed primary (Remove destructive / Done / Close).

### OrganizationView

```
OrganizationView (ScrollView → VStack)
└─ switch reader.state {
     case .loading           → ProgressView centered (top-padding)
     case .empty             → emptyContent
     case .loaded(org, _)    → loadedContent(org)
     case .error(msg)        → LeafBanner.danger (top) + retry
     case .removedFromOrg    → EmptyView() (RootView preempts)
   }

emptyContent:
  VStack(spacing: LeafSpace.xxl) {
    LeafSection(title: "Organization", description: "Create your personal org.") {
      VStack(alignment: .leading, spacing: LeafSpace.md) {
        Text(intro_copy).font(LeafType.body.regular).foregroundStyle(LeafColor.text.secondary)
        LeafCard.raised(padding: .regular) {
          VStack(spacing: LeafSpace.md) {
            TextField("My Workspace", text: $nameInput) ← rounded border + LeafType.body.regular
            HStack {
              Spacer()
              LeafButton.primary("Create personal org", action: submit) ← disabled when trimmed.empty
            }
          }
        }
      }
    }
    LeafSection(title: "Or join a team", description: "If a teammate invited you, accept the invite instead.") {
      LeafButton.secondary("Accept invite", action: { showingAcceptSheet = true })
    }
  }

loadedContent(org):
  LeafSection(title: "Organization") {
    LeafCard.raised(padding: .regular) {
      VStack(alignment: .leading, spacing: LeafSpace.md) {
        LeafListRow(primary: org.name, secondary: nil) ← title large
        LeafDivider()
        LeafListRow(primary: "Created \(org.createdAt formatted)", secondary: nil) ← body regular
        LeafDivider()
        Text("Single-org-per-device — to switch, wipe local data first.")
          .font(LeafType.body.small)
          .foregroundStyle(LeafColor.text.tertiary)
      }
    }
  }
```

**Key choices:**

- Drop "WORKSPACE NAME" / "CREATED" leafLabelStyle micro-labels — LeafSection title carries hierarchy.
- Drop the 540pt-content / 580pt-card max-width constraints — LeafCard inside ScrollView handles natural width.
- "Or join a team" was a Divider() + leafLabelStyle inside same VStack; promote to its own LeafSection (clearer hierarchy).
- Keep `.sheet(isPresented: $showingAcceptSheet) { AcceptInviteSheet() }` modifier — preserved.

### WindowSettingsView (+ 3 sub-sections + FoldersSettings)

```
WindowSettingsView
└─ ScrollView → VStack(spacing: LeafSpace.xxl) {
     GeneralSettingsSection(launchAgent:, updater:)
     FoldersSettings(service: watchedFolders)
     PrivacySettingsSection()
   } padding(LeafSpace.xxl)
```

Top-level "SETTINGS / Settings" header chrome dropped. Each sub-section renders own LeafSection block.

#### GeneralSettingsSection

```
VStack(spacing: LeafSpace.xl) {
  LeafSection(title: "Background collection",
              description: "Agent runs as a LaunchAgent managed by macOS. Disable anytime in System Settings → General → Login Items.") {
    LeafCard.raised(padding: .regular) {
      VStack(spacing: LeafSpace.md) {
        LeafToggle(title: "Enable background collection", isOn: <binding>)
        LeafDivider()
        LeafListRow(primary: "Status", secondary: launchAgent.statusDescription) {
          LeafDot(tone: statusTone, size: .md)   ← leading
        } trailing: { EmptyView() }
        if let error = launchAgent.lastErrorMessage {
          LeafDivider()
          LeafBanner(tone: .danger, title: "Last error", description: error)
        }
        HStack {
          Spacer()
          LeafButton("Refresh status", variant: .secondary, action: launchAgent.refreshStatus)
        }
      }
    }
  }
  LeafSection(title: "Updates",
              description: "Updates served from updates.gundem.tech. Sparkle 2 + EdDSA-signed appcast.") {
    LeafCard.raised(padding: .regular) {
      VStack(spacing: LeafSpace.md) {
        LeafListRow(primary: "Version", secondary: nil) {} trailing: {
          Text(versionDisplay).font(LeafType.mono.regular).foregroundStyle(LeafColor.text.tertiary)
        }
        HStack {
          Spacer()
          LeafButton("Check for Updates…", variant: .secondary, action: updater.checkForUpdates)
        }
      }
    }
  }
}
```

statusTone: `.enabled → .success`, `.requiresApproval → .warning`, `.notRegistered/.notFound/@unknown → .muted`.

#### PrivacySettingsSection

```
LeafSection(title: "Privacy",
            description: "Phase 1 uses a hardcoded minimal blocklist (Leaf's own processes + system UI). Editable per-app Share Controls land in Phase 2.") {
  EmptyView()
}
```

(No LeafCard — section description carries everything; content slot empty acceptable since LeafSection content is `@ViewBuilder` + EmptyView trivially renders.)

#### FoldersSettings

```
LeafSection(title: "Watched folders",
            description: "Leaf отслеживает file-level activity (создание, изменение, удаление) только в выбранных папках. L4 (default) — popover показывает только имя папки. L5 — basename файла. Toggle применяется только к новым событиям. История удалённой папки остаётся локально.",
            cta: { LeafButton("Add…", variant: .secondary, icon: .asset(LeafIcons.action.add), action: addFoldersViaPanel) }) {
  if service.folders.isEmpty {
    LeafEmptyState(icon: LeafIcons.object.folderEmpty,
                   title: "No watched folders",
                   description: "Add a folder to track file activity in your projects.")
  } else {
    LeafCard.raised(padding: .tight) {
      VStack(spacing: 0) {
        ForEach(service.folders, id: \.id) { folder in
          folderRow(folder)
          if !last { LeafDivider() }
        }
      }
    }
  }
  if let error = service.lastErrorMessage {
    LeafBanner(tone: .danger, title: "Couldn't add folder", description: error)
  }
}

folderRow(folder):
  HStack(spacing: LeafSpace.md) {
    VStack(alignment: .leading, spacing: LeafSpace.xs) {
      Text(folder.lastPathComponent).font(LeafType.body.regular).foregroundStyle(LeafColor.text.primary)
      HStack(spacing: LeafSpace.md) {
        Picker(selection: granularityBinding) { L4 / L5 }.pickerStyle(.segmented).frame(maxWidth: 220)
        LeafToggle(title: "Enabled", isOn: enabledBinding)
      }
    }
    Spacer()
    LeafIconButton(asset: LeafIcons.object.trash, variant: .ghost, size: .md, action: { service.remove(id: folder.id) })
  }
  .padding(.horizontal, LeafSpace.md)
  .padding(.vertical, LeafSpace.md)
  .help(folder.path)
```

**Decision:** keep native `Picker(.segmented)` for L4/L5 — LeafTab is wrong primitive (tabs = view-mode picker; L4/L5 = property setter). Picker-segmented → semantic match. Native macOS chrome inside LeafCard acceptable here (small inline form control, not a screen-level Form).

### ProfileView

```
ProfileView (ScrollView → VStack)
└─ VStack(alignment: .leading, spacing: LeafSpace.xxl) {
     header
     statsContent
     Spacer(minLength: 0)
   } .padding(LeafSpace.xxl)

header:
  HStack(spacing: LeafSpace.lg) {
    LeafAvatar(initials: initial, size: .lg)
    VStack(alignment: .leading, spacing: LeafSpace.xs) {
      Text(fullName).font(LeafType.title.medium).foregroundStyle(LeafColor.text.primary)
      Text("Leaf · Local user").font(LeafType.body.regular).foregroundStyle(LeafColor.text.secondary)
    }
    Spacer()
  }

statsContent:
  if case .loaded(let snapshot, _) = reader.state {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: LeafSpace.lg)], spacing: LeafSpace.lg) {
      LeafMetricCard(title: "Active streak", value: "\(snapshot.activeDaysInRow) days")
      LeafMetricCard(title: "Deep work streak",
                     value: snapshot.deepWorkStreak.days == 0
                            ? "—"
                            : "\(snapshot.deepWorkStreak.days)d \(formatHours(snapshot.deepWorkStreak.totalSeconds))")
    }
  } else {
    Text("Stats will appear once the agent collects today's activity.")
      .font(LeafType.body.regular)
      .foregroundStyle(LeafColor.text.secondary)
  }
```

**Key choices:**

- Drop "PROFILE" leafLabelStyle micro-label + duplicate H1 "fullName" line — LeafType.title.medium directly inside header.
- Drop avatar overlay-stroke (decorative; LeafAvatar surface.inset background carries identity).
- LeafMetricCard caption parameter doesn't exist — fold caption semantics into title:
  - "Active days / 5 / in a row" → "Active streak / 5 days" (title carries unit context, value carries quantity).
  - "Deep streak / 1d 3h / total" → "Deep work streak / 1d 3h" (title carries verb anchor, value compact).
- Adaptive grid min 220pt (D3 Team grid uses 240pt — but D3 cards have avatars; Profile cards are number-first, narrower works). Max 320pt prevents cards spanning whole width on resize.

### RemovedFromTeamBanner

```
RemovedFromTeamBanner(orgName)
└─ LeafEmptyState(
     icon: LeafIcons.object.userError,
     title: "You've been removed from \(orgName)",
     description: "Your local data remains on this device, but you can no longer send presence to teammates. To start fresh, wipe local team data via Settings (coming soon)."
   )
   .frame(maxWidth: .infinity, maxHeight: .infinity)
   .background(LeafColor.surface.canvas.ignoresSafeArea())
```

LeafEmptyState carries hero icon + title + description. CTA omitted (no action — info-only). Background takes full window per RootView preempt contract.

### MenuBarContent

```
MenuBarContent
└─ if hasCompletedOnboarding { normalBody } else { OnboardingView(onDone: …) }

normalBody:
  LeafMenuBarLayout {
    VStack(alignment: .leading, spacing: LeafSpace.lg) {
      if !launchAgent.isEnabled { agentOffBanner }
      permissionsBanner                    ← AX / FDA combo banner
      hero                                 ← FOCUS TODAY label + total focus duration
      content                              ← .loading / .notConfigured / .empty / .error / .loaded
      controls                             ← Open / Quit footer-row
    }
    .onAppear / .onDisappear preserved
  }

agentOffBanner:
  LeafBanner(tone: .warning,
             title: "Background collection is off",
             ctaTitle: "Enable",
             onCTA: openMainWindowToSettings)

permissionsBanner (combo):
  if !permissions.axGranted {
    LeafBanner(tone: .warning, title: "Accessibility disabled", ctaTitle: "Grant", onCTA: permissions.openAXSettings)
  } else if !permissions.fdaGranted {
    LeafBanner(tone: .warning, title: "Full Disk Access disabled",
               description: "Watched Folders won't track ~/Documents",
               ctaTitle: "Grant", onCTA: permissions.openFDASettings)
  }

hero:
  VStack(alignment: .leading, spacing: LeafSpace.xs) {
    Text("FOCUS TODAY").leafSectionLabel().foregroundStyle(LeafColor.text.tertiary)
    Text(focusTotalDisplay)
      .font(LeafType.title.large)
      .foregroundStyle(LeafColor.text.primary)
      .monospacedDigit()
  }

content:
  switch reader.state {
    case .loading                 → ProgressView controlSize(.small) centered
    case .notConfigured/.empty/.error(msg) → Text(msg).font(LeafType.body.small).foregroundStyle(LeafColor.text.secondary)
    case .loaded(snapshot, _)     → loadedContent(snapshot)
  }

loadedContent(snapshot):
  VStack(alignment: .leading, spacing: LeafSpace.md) {
    topAppsList                           ← LeafCard.rest wrapping LeafListRow chain (max 3 apps)
    if !providerLines.isEmpty {
      LeafDivider()
      VStack(alignment: .leading, spacing: LeafSpace.xs) {
        ForEach(lines) { Text(line).font(LeafType.body.small).foregroundStyle(LeafColor.text.secondary) }
      }
    }
  }

topAppsList: LeafCard.rest(padding: .tight) {
  VStack(spacing: 0) {
    ForEach(topApps) { entry in
      LeafListRow(primary: AppNameResolver.shared.displayName(for: entry.bundleID),
                  secondary: nil) {} trailing: {
        Text(formatDuration(entry.duration))
          .font(LeafType.mono.small)
          .foregroundStyle(LeafColor.text.tertiary)
      }
    }
  }
}

controls:
  HStack(spacing: LeafSpace.sm) {
    LeafButton.primary("Open", icon: .asset(LeafIcons.action.external), action: openMainWindow)
    Spacer()
    Button("Quit") { NSApp.terminate(nil) }
      .buttonStyle(.borderless)
      .foregroundStyle(LeafColor.text.secondary)
      .keyboardShortcut("q")
  }
```

**Why keep native `Button("Quit")` instead of LeafButton:** LeafButton.ghost on a destructive/text-only "Quit" reads heavier than a borderless system text button; macOS menu-quit conventional pattern. Acceptable substrate deviation для system-conventional control.

### Onboarding (4 views)

```
OnboardingView (popover: 320pt fixed)
└─ VStack(alignment: .leading, spacing: LeafSpace.md) {
     header                              ← Leaf icon + "Welcome to Leaf" + step dots
     LeafDivider()
     stepContent                         ← state-routed @ViewBuilder (preserved)
   } .padding(LeafSpace.lg).frame(width: 320)

header:
  VStack(alignment: .leading, spacing: LeafSpace.sm) {
    HStack(spacing: LeafSpace.xs) {
      Image.leafAsset(LeafIcons.brand.leafFill).frame(width: 14, height: 14).foregroundStyle(LeafColor.accent.primary)
      Text("Welcome to Leaf").font(LeafType.title.small).foregroundStyle(LeafColor.text.primary)
      Spacer()
    }
    stepDots
  }

stepDots:
  HStack(spacing: LeafSpace.xs) {
    ForEach(OnboardingStep.allCases, id: \.self) { s in
      Circle()
        .fill(s.index <= step.index ? LeafColor.accent.primary : LeafColor.border.subtle)
        .frame(width: 6, height: 6)
    }
  }
```

step content per step (welcome/ax/fda/team/done) — VStack with LeafType.title.small (heading) + LeafType.body.small (description, text.secondary) + LeafButton.primary (action) + optional LeafButton.ghost "Skip for now" (if step skippable).

`.team` substep — preserved (`.choice / .create / .join / .waiting`); each sub-view migrated independently.

`grantStatus(granted:)` helper:
- granted → LeafIconLabel(.asset(LeafIcons.status.successFill), title: "Granted", iconTint: LeafColor.status.success, titleStyle: LeafType.body.small)
- not granted → Text("Waiting…").font(LeafType.body.small).foregroundStyle(LeafColor.text.secondary)

#### CreateTeamStepView, JoinTeamStepView, WaitingForInviteView

Pattern: VStack(alignment: .leading, spacing: LeafSpace.md) {
  Text(title).font(LeafType.title.small).foregroundStyle(LeafColor.text.primary)
  Text(description).font(LeafType.body.small).foregroundStyle(LeafColor.text.secondary)
  ... form fields / progress / etc (TextField rounded; field-label = LeafType.body.small text.tertiary uppercase via leafSectionLabel)
  HStack {
    LeafButton.ghost("Back", action: onCancel) ← destructive-less back
    Spacer()
    LeafButton.primary(<advance-CTA>, action: <advance>, isLoading: <where applicable>)
  }
}

JoinTeamStepView preserves JoinCode load + ShareTemplateButton wiring 1:1.
WaitingForInviteView preserves ProgressView + manual-paste fallback.

### ShareTemplateButton

```
HStack(spacing: LeafSpace.sm) {
  LeafButton("Copy", variant: .primary, icon: .asset(LeafIcons.comm.copy), action: copyToPasteboard)
  LeafButton("Mail", variant: .secondary, icon: .asset(LeafIcons.comm.email), action: openMail)
  LeafButton("Messages", variant: .secondary, icon: .asset(LeafIcons.comm.message), action: openMessages)
}
```

Behavior: copyToPasteboard / openMail / openMessages helpers preserved 1:1 (NSPasteboard + NSWorkspace.shared.open).

### Token previews migration (LeafSheetLayoutPreview, LeafOnboardingStepLayoutPreview)

Single-line edit per file: replace
- `LeafProminentButton(action: {}) { Text("Continue") }` → `LeafButton("Continue", variant: .primary, action: {})`
- `LeafSecondaryButton(action: {}) { Text("Back") }` → `LeafButton("Back", variant: .secondary, action: {})`

(or equivalent — let plan code listing show exact substitution.)

## State machine UX

(All preserved 1:1 — D4 — pure UI substrate. State enums + transition logic untouched.)

### Sheets

- GenerateInviteSheet: 4-state (idle / generating / ready / error) × 2 inputModes (paste / template).
- AcceptInviteSheet: 6-state (idle / fetching / otpEntry / accepting / success / error) + 3 input paths (deep-link / scenePhase clipboard / manual paste).
- RemoveMemberSheet: 4-state (idle / removing / success / error).

### OrganizationView

- 5-state OrgReader (loading / empty / loaded / error / removedFromOrg).

### Onboarding

- 5-step OnboardingStep (welcome / ax / fda / team / done) + 4-substep TeamSubStep (choice / create / join / waiting).
- Auto-advance triggers preserved (`.onChange` permissions / orgReader / inviteAcceptReader).

### Settings

- LaunchAgent 4-status × FoldersService N-folders × Updates check.

## Token discipline guard extension

D2 introduced two-tier scope (BASE + MIGRATION). D3 extended MIGRATION_PATHS. **D4 finalises** в two ways:

1. **MIGRATION_PATHS = entire `Leaf/Views/`** (минус `Leaf/Views/Tokens/` BASE). After D4 — все production view files migrated; MIGRATION inherits BASE checks AND bans old-palette refs everywhere в Views/.

   Implementation: replace explicit per-screen MIGRATION list with single `Leaf/Views/` entry; BASE_PATHS already excludes via `Tokens/` separate entry (BASE rules apply там instead of MIGRATION). `Leaf/Views/Tokens/` dir under BASE — single check_pattern_in_paths invocation handles via path argument.

2. **RETIRED tier** — new third tier banning old-palette names anywhere в `Leaf/`:

   ```bash
   RETIRED_PATHS=(
     "${REPO_ROOT}/Leaf"
   )
   ```

   Patterns:
   - `Color\.leaf(Ink|Background|Card|Accent|AccentDeep|Signal|Muted)\b` — old-palette Color extensions
   - `\bFont\.leaf(Title|Headline|Metric|Label|Body|Caption)\b` — old-palette Font extensions
   - `\.font\(\.leaf(Title|Headline|Metric|Label|Body|Caption)\)` — call-site form
   - `\.leafLabelStyle\(\)` — old text helper
   - `\bGlassCard\b` — old wrapper struct
   - `\bLeafProminentButton\b|\bLeafSecondaryButton\b|\bLeafGlassGroup\b` — old glass wrappers
   - `\bMetricCard\b` (excluding `\bLeafMetricCard\b` / `\bLeafMetricTokens\b` / `\bLeafMetricCardPreview\b` etc) — exclude regex `Leaf(MetricCard\|MetricTokens\|MetricAmbient\|MetricDelta\|MetricInline)`
   - `(?:^|[^a-zA-Z])EmptyStateView\b` (regex literal — POSIX ERE no lookbehind, accept matches without LeafEmptyState false positives via word boundary `\b`; LeafEmptyState's "View"-suffix pattern doesn't match "EmptyStateView" because "LeafEmptyState" lacks the trailing "View" — fine) → ban `\bEmptyStateView\b`
   - `Color\.leafCategory\(|\.leafCategory\(` — function form
   - `BannerView\b` — old menu-bar banner wrapper

   (`\b` word-boundary in `grep -E` POSIX ERE works but POSIX ERE doesn't support all PCRE features — script will validate via real-codebase cleanliness after D4 retirement; impl tunes regex per surfacing false positives.)

3. **Exclude regex** for RETIRED checks must skip own check-tokens.sh script lines (script literally references the patterns — false-positive on its own grep). Use `--exclude="check-tokens.sh"` или explicit exclude regex in check_pattern_in_paths invocation.

   Also exclude self-test fixture file `scripts/tests/test-check-tokens.sh` (intentionally contains old-palette strings inside `<<EOF>>` heredocs).

   Actually, RETIRED_PATHS = `Leaf/` (not `${REPO_ROOT}` whole tree) — `scripts/` is outside, so fixture and script naturally excluded. ✓

**Self-test extension:**

- Case 18: clean-Leaf-fixture (LeafColor / LeafType / LeafSpace refs) inside `Leaf/Views/Tokens/` — passes (BASE scope, RETIRED tier doesn't fire because no old-palette refs).
- Case 19: bad-Leaf-fixture (`.leafLabelStyle()` ref) inside `Leaf/Views/Tokens/` — fails (RETIRED tier catches even в BASE path).
- Case 20: bad-Leaf-fixture (`Color.leafInk` ref) inside `Leaf/Theme/__test_fixture__/` — fails (RETIRED tier catches в Theme too).
- Case 21: clean-Leaf-fixture passes whole MIGRATION sweep (entire Leaf/Views/ minus Tokens/ под guard).
- Case 22: `LeafMetricCard` token usage не triggers `MetricCard` ban — exclude regex preserves new helper.

(Cases 1-17 preserved — D2/D3 self-test cases continue passing.)

## Out-of-scope для D4 (carry-over post-Track-2)

- **Phase 5.4** — presence broadcast / presence_outgoing / presence_history / Share Controls UI / blocklist editor / per-app whitelist / per-event-type whitelist UI.
- **Phase 5.5.D candidates** — pending invites D7 enhancements (per-row Refresh, "Joined N min ago" ghost row, bulk Revoke-all-expired, inviteeDisplayNameHint capture).
- **Phase 5.6** — auto-poll loop через HEAD `/v1/invite/<token>` + background scheduler.
- **Phase 4.7 carry-overs** — non-blocking Linear cleanups (4.7.B/C); GitHub UTC DateFormatter hoist.
- **Phase 4.9** — DefaultModeClassifier + mode_history table + mode-aware MCP tools.
- **In-app AI / BYOK** — out per architecture doc.
- **Settings new sections** — "Updates channel" picker, "Storage" stats, "Right to deletion" CTA — additive content beyond D4 scope.
- **Onboarding architectural lift** — move from MenuBarExtra popover to standalone Window scene (full-bleed `LeafOnboardingStepLayout` adoption) — out. Architectural change.
- **macOS Settings scene migration** — replace WindowSettingsView (window tab) with macOS-style `Settings { ... }` scene — out. Settings tab as part of unified product surface preserved per OQ-1 decision.
- **D4 LeafCard.glass adoption inside sheets** — out (anti-pattern: glass-on-glass).

## Open questions / risks (decided)

Standalone questions raised during brainstorm + Discovery (no user в loop — каждое resolved with documented tradeoff). All decisions enacted in spec above; this section is the audit trail.

- **OQ-1: Settings — native `Form(formStyle: .grouped)` retire vs keep.** macOS HIG + Settings scene идиоматично используют `Form(formStyle: .grouped)`. Наш WindowSettingsView — tab внутри окна, не отдельный Settings scene. **Decided:** drop Form everywhere в Settings (WindowSettingsView, GeneralSettingsSection, PrivacySettingsSection, FoldersSettings). Replace each Section with LeafSection block. Reason: Settings tab — часть unified product surface, не системного Preferences окна; visual consistency со всем остальным приложением (D2/D3 dropped Form in Connections per OQ-10 — D4 follows same precedent для Settings). **Trade-off:** loses macOS-native form chrome (rounded grouped sections). Acceptable: D1 substrate's LeafSection + LeafCard achieves comparable visual hierarchy with consistent token usage.

- **OQ-2: MenuBar background — LeafMenuBarLayout vs system MenuBarExtra material.** SwiftUI `MenuBarExtra(...).menuBarExtraStyle(.window)` provides custom popover content (наш case). Внутри can apply own background. LeafMenuBarLayout (T3 template) — `LeafColor.surface.raised` background, fixed 360pt width. **Decided:** adopt LeafMenuBarLayout. Preserves per-token colour discipline; system MenuBarExtra material remains через popover container chrome (vibrancy). **Trade-off:** width changes 280pt → 360pt (current MenuBarContent uses 280; D1 LeafMenuBarLayoutTokens.width = 360). Acceptable per Snapshot Replacement: D1 substrate is source of truth; UI shifts +80pt acceptable; `LeafMenuBarLayoutTokens.width` is single-line tunable if 360 surfaces UX issues.

- **OQ-3: Sheet chrome — LeafSheetLayout vs ad-hoc VStack+padding+frame.** D1 substrate has LeafSheetLayout template (T2). Current sheets use VStack `.padding(28).frame(width: 560/520, height: 600/580/380)`. **Decided:** adopt LeafSheetLayout for all 3 sheets. **Trade-off:** loses fixed-width sheet sizing — sheets size к content (system natural sizing) + LeafSheetLayoutTokens minWidth/minHeight (480/360). RemoveMemberSheet may shrink horizontally (current 520pt → ~480pt). Acceptable per Snapshot Replacement.

- **OQ-4: Sheet header — keep ad-hoc `Text("ACCEPT INVITE").leafLabelStyle() + Text("Join your team").font(.leafHeadline)` vs delegate to LeafSheetLayout title.** **Decided:** delegate to LeafSheetLayout title — single title source, drops manual section-label-style chrome. Title strings: "Add a team member" (GenerateInvite), "Join your team" (AcceptInvite), "Remove member" (RemoveMember). RemoveMemberSheet's dynamic "Remove \(displayName) from the team?" question moves to first inner LeafCard primary text — shouldn't conflict with template title (template title = generic; primary text = specific member).

- **OQ-5: AcceptInviteSheet `.frame(width: 560, height: 600)` strict-preservation.** Current sheets explicitly size; under LeafSheetLayout, sheets size к content + min-frame tokens. **Decided:** drop strict frame. AcceptInviteSheet is the busiest (otpCard with multiple TextField rows + attempts feedback + display name field) — minHeight 360 + content sizing should clear; if content overflows bottom edge на successCard (smaller content), sheet system auto-sizes. **Trade-off:** sheet height might oscillate between states (otp 600pt-ish, success 200pt-ish). Acceptable — Apple-native sheet behaviour mirrors this.

- **OQ-6: GenerateInviteSheet input mode picker — native Picker(.segmented) vs LeafTab.** Picker(.segmented) — system idiom. LeafTab — D1 organism (tabs are view-mode picker). **Decided:** LeafTab. Reason: D3 OQ-3 precedent (Activity mode picker via LeafTab); InputMode = "which input flavor" aligns with tab-segments pattern; visual consistency with rest of app. **Trade-off:** LeafTab supports `disabled` only via inner CTA disabling (not whole-tab disable per state) — `.generating` state must rely on inner content disabling to prevent mode-switch during in-flight generation. Acceptable.

- **OQ-7: Settings background-collection status row (Circle + status text) — LeafListRow + LeafDot vs ad-hoc HStack.** Current uses native HStack with raw Circle + Text + foregroundStyle. **Decided:** LeafListRow with LeafDot leading + LeafType.body.regular trailing label. Dot `.tone` derived from launchAgent.status (.enabled→.success, .requiresApproval→.warning, default→.muted). Trade-off: LeafListRow has hover state (background flips to surface.raised on hover) — makes the status row look "interactive" although it isn't. Mitigated: status row inside LeafCard.raised already has elevated surface; hover-state delta minimal.

- **OQ-8: PrivacySettingsSection content — LeafSection with EmptyView content slot vs LeafCard with text content.** Privacy section is informational only (no controls). Two options: (a) LeafSection(title:, description: long-text) {} — description carries copy; (b) LeafSection(title:) { LeafCard.raised { Text(copy) } } — text inside card. **Decided:** (a) — LeafSection.description handles copy natively; LeafCard adds visual weight without functional add. Card chrome useful for grouping interactive controls; not for prose-only blocks.

- **OQ-9: FoldersSettings folder row — LeafListRow with custom trailing slot vs ad-hoc HStack.** LeafListRow's primary/secondary slots are String-typed — folder row needs primary (folder name) + nested HStack of (Picker + Toggle). Doesn't fit LeafListRow's contract cleanly. **Decided:** ad-hoc HStack folderRow (NOT LeafListRow). Pattern: HStack { VStack { name + (Picker + Toggle row) } + LeafIconButton trash }. Token discipline preserved (LeafSpace / LeafType / LeafColor used internally), just doesn't use LeafListRow organism. **Alternative considered:** extend LeafListRow with `controls: () -> ...` slot — out-of-scope D4 substrate change. **Trade-off:** loses LeafListRow hover state. Acceptable — folder row's destructive trash button is the action affordance; whole-row hover not meaningful.

- **OQ-10: Folders empty state — inline ad-hoc empty row vs LeafEmptyState.** Current: small VStack with folder-icon + "No watched folders" + caption — narrow inline empty (16pt vertical padding). LeafEmptyState — vertically-centered substrate (`.padding(.vertical, LeafEmptyStateTokens.verticalPadding)`). **Decided:** LeafEmptyState. Same surface pattern as Activity / Team empty states — visual consistency. **Trade-off:** more vertical space than current narrow empty. Acceptable; Settings ScrollView handles overflow.

- **OQ-11: Folders — `Picker(.segmented) for L4/L5` vs LeafTab.** L4/L5 — property setter (boolean-ish). LeafTab — view-mode picker (display-mode segmentation). **Decided:** keep native `Picker(.segmented)` — semantic match для property-setter; LeafTab abuse otherwise. Native Picker chrome inside LeafCard acceptable per substrate "system primitive embedded inside D1 surface" pattern (sheet TextFields are also native).

- **OQ-12: ProfileView avatar — LeafAvatar.lg vs custom Circle.** Custom: 64pt Circle with overlay-stroke + leafAccent.opacity tints. LeafAvatar.lg = 56pt. **Decided:** LeafAvatar.lg (size: .lg). Drop overlay-stroke (decorative; avatar surface.inset background carries identity). 56pt vs 64pt — minor; substrate token wins. **Alternative considered:** add `LeafAvatar.Size.xl = 64` token. Rejected — single-use-site не warrant new T3 token; Profile aesthetic doesn't require beyond .lg (Notion / Linear profile pages typically 48-56pt avatar).

- **OQ-13: ProfileView LeafMetricCard — caption parameter добавлять vs fold into title.** LeafMetricCard signature: `(title:, value:, delta:, sparklineValues:, isFresh:)` — no caption. Current MetricCard had caption. **Decided:** fold caption into title, drop caption surfacing. "Active days / 5 / in a row" → "Active streak / 5 days". **Trade-off:** loses caption-secondary semantics. Acceptable: title carrying unit context is cleaner; substrate doesn't need extension. **Alternative considered:** extend LeafMetricCard with `caption: String? = nil`. Rejected — substrate change with single use-site; cleaner fold.

- **OQ-14: ProfileView header — LeafSection wrap vs naked HStack.** LeafSection requires title-string. Profile header = "PROFILE / fullName / Leaf · Local user" pattern; section title = "Profile" duplicates fullName-anchor. **Decided:** naked HStack header (no LeafSection wrap). Avatar + name (LeafType.title.medium) + caption (LeafType.body.regular text.secondary) — direct presentation; no section title needed. Stats grid below — also naked (no "Stats" section title — adaptive grid contextually self-explanatory).

- **OQ-15: RemovedFromTeamBanner — LeafEmptyState vs LeafCard hero vs ad-hoc.** Current: ad-hoc VStack with image + headline + body, full-screen. LeafEmptyState matches pattern (icon + title + description, vertically-centered). **Decided:** LeafEmptyState. CTA omitted (no action — info-only; "wipe local data" is out-of-MVP). Background → `LeafColor.surface.canvas.ignoresSafeArea()`. Full-screen `.frame(maxWidth: .infinity, maxHeight: .infinity)` preserved.

- **OQ-16: MenuBarContent — LeafMenuBarLayout adoption vs preserving 280pt width.** D1 substrate `LeafMenuBarLayoutTokens.width: 360`. Current 280. **Decided:** adopt 360pt per LeafMenuBarLayout. Trade-off discussed in OQ-2.

- **OQ-17: MenuBarContent FOCUS-TODAY hero — LeafKPI primitive vs ad-hoc Text.** D1 has metric primitives (LeafMetricAmbient = title-display number + delta + sparkline). Hero = "FOCUS TODAY" label + 28-32pt total focus duration. LeafMetricAmbient overkill (no delta, no sparkline). **Decided:** ad-hoc composition with LeafType.label uppercase tracked + LeafType.title.large primary monospacedDigit. Cleaner than primitive. **Alternative considered:** LeafMetricCard. Rejected — card-chromed surface не aligns with menu-bar compact hero (no card border / background needed; popover chrome is the surface).

- **OQ-18: MenuBarContent banners — LeafBanner adoption vs preserve BannerView.** BannerView (40 LOC, 3 callers all in MenuBarContent) — single-consumer wrapper. **Decided:** retire BannerView; replace 3 callsites with LeafBanner inline. Tone .warning matches current orange icon. CTA `.ctaTitle/.onCTA` matches "Grant" / "Enable" semantics. **Trade-off:** subtitle (FDA banner) folds into description. Visual difference minimal.

- **OQ-19: MenuBarContent quit button — LeafButton.ghost vs preserve native borderless.** LeafButton ghost = roundedRect background with hover. Native `Button("Quit").buttonStyle(.borderless)` = text-only, no background. **Decided:** preserve native borderless для Quit. Reason: macOS menu-quit conventional pattern (text-only quit, no chrome); LeafButton.ghost reads heavier than expected for destructive system action. ⌘Q shortcut preserved.

- **OQ-20: Onboarding — LeafOnboardingStepLayout adoption vs inline migration.** Template designed full-bleed (`.frame(maxWidth: .infinity, maxHeight: .infinity)` + Spacer-Spacer-content vertical centering). OnboardingView lives inside `MenuBarExtra(...).menuBarExtraStyle(.window)` popover with `.frame(width: 320)`. Spacer() inside maxHeight: .infinity без external constraint → ambiguous. **Decided:** inline migration, NOT LeafOnboardingStepLayout. Migrate Onboarding views на D1 atoms (LeafType / LeafButton / LeafColor / LeafSpace / LeafIcons). Keep `.frame(width: 320)` popover shape. **Trade-off:** template not consumed by production code (only TokensPreview shows it). Acceptable — template remains substrate library for v1.1 architectural change to full-window onboarding (out-of-scope D4). **Alternative considered:** lift OnboardingView to standalone Window scene. Rejected — architectural change beyond UI migration; preserves popover-style onboarding per LeafApp contract.

- **OQ-21: Onboarding step dots — preserve Circles vs LeafOnboardingStepLayout capsules.** Current: Circles (6×6pt) row, accent vs secondary opacity. Template uses Capsule (.frame(height: progressBarHeight: 4)). **Decided:** preserve Circles (popover-compact); replace `Color.accentColor` → `LeafColor.accent.primary`, `Color.secondary.opacity(0.3)` → `LeafColor.border.subtle`. Token-discipline maintained, visual unchanged. Capsules — full-bleed pattern; popover Circles read tighter.

- **OQ-22: Old palette retirement — hard delete vs deprecated stub.** **Decided:** hard delete. CLAUDE.md root rule "Avoid backwards-compatibility hacks". Verified zero consumers grep'ом during Discovery (post-D4 migration). **Trade-off:** breaks any in-flight branch that touches old palette — mitigated by Track 2 collective merge gate (D4 ships → main only after acceptance gate; until then, old palette deletion isolated to D4 branch).

- **OQ-23: `Leaf/Views/Window/Shared/EmptyStateView.swift` — orphaned, delete safety.** Discovery confirms zero consumers (grep clean). Phase 4.x relic from "team coming soon" placeholder. **Decided:** safe to delete immediately. **Trade-off:** none.

- **OQ-24: `Leaf/Theme/CategoryColors.swift` — orphaned post-D3.** D3 SessionRow drop'нул category dot (D3 OQ-6). Discovery confirms zero consumers. **Decided:** safe to delete. **Trade-off:** none.

- **OQ-25: `Leaf/Views/BannerView.swift` consumers grep.** Confirmed: 3 callsites all in MenuBarContent. **Decided:** delete after MenuBarContent migration to LeafBanner.

- **OQ-26: Token-discipline guard scope after D4.** Three options surveyed: (a) MIGRATION_PATHS = entire `Leaf/Views/` minus Tokens/; (b) collapse to single BASE tier (no MIGRATION layer); (c) status quo (explicit MIGRATION list per phase). **Decided:** (a). Reason: explicit MIGRATION = entire Views/ cleanly states "all production view code under strict guard"; sheet exclusions (D3 carry-over) cleared; single-tier ban inheritance preserved. (b) collapses defense-in-depth — old-palette ban only applies if MIGRATION inherits; merging tiers loses the differentiated check. (c) requires per-phase update — но after D4 there are no more phases в Track 2; static MIGRATION = whole-Views/ stable.

- **OQ-27: Compile-time regression test для retirement (RETIRED tier).** Hard delete = compile breakage if consumer remains. RETIRED tier check = secondary defense (catches comments / strings / copy-paste from git history). **Decided:** add RETIRED tier scoped to entire `Leaf/` (Theme + Views) banning old-palette names (regex list per § "Token discipline guard extension"). **Trade-off:** false positives risk (e.g. someone introduces variable named `metricCardSize` — `\bMetricCard\b` matches). Mitigated via exclude regex (`Leaf(MetricCard|MetricTokens|...)`).

- **OQ-28: `LeafType.swift` doc-comment refresh.** D3 token added `LeafType.mono.large` w/ comment referencing "Snapshot Replacement migration — old palette stays until D4 ships". After D4 — "until D4 ships" rotted. **Decided:** update comment в T-N (single line edit). New comment: "Snapshot Replacement migration completed in Track 2 D4. `Text.leafSectionLabel()` is the canonical section-label text helper across the app." (or similar — drop legacy `leafLabelStyle` reference).

- **OQ-29: Whitepaper sync content для Track 2 ship.** D4 implementation moat НЕ публикуется (component внутренности, retirement decisions, RETIRED tier regex). Architectural framing на public-safe уровне: "Track 2 — full design-language refresh: tokenized 3-tier substrate (primitive → semantic → component) + atoms/molecules/organisms/templates библиотека + миграция всех production surfaces. Old palette retired." **Decided:** D4 plan task TN places placeholder for whitepaper sync — concrete file pick deferred до post-merge ship session (per Track 2 charter — whitepaper sync deferred until track ships; D4 ship = Track 2 ship).

- **OQ-30: TokensPreview screen (`⌘⌥T`) preservation после retirement.** TokensPreview lives in `Leaf/Views/Tokens/` (BASE scope). Subviews include LeafSheetLayoutPreview / LeafOnboardingStepLayoutPreview that consume LeafProminentButton / LeafSecondaryButton (both deleted). **Decided:** preview files migrate to LeafButton (small line-edit per file). TokensPreview remains debug-only `⌘⌥T` accessible per D1 acceptance. Token preview migration is part of D4 scope (not separate retirement task).

- **OQ-31: Migration order (T1...TN ordering).** Apply same dependency principle что D3: leaf node files first (rows / atoms сами не зависят от других migrating files), parents next (containers consume migrated children), deletions last (delete файлов после verifying consumers мигрированы). D4 specific dependency flow:
  1. ShareTemplateButton (consumed by GenerateInviteSheet, JoinTeamStepView)
  2. Onboarding step views (consumed by OnboardingView)
  3. AcceptInviteSheet (consumed by OnboardingView via .sheet, also OrganizationView via .sheet)
  4. Sheets (3) parallel (no inter-dependencies)
  5. Window screens (4) parallel (Profile / Organization / WindowSettings sub-sections / RemovedFromTeamBanner — independent)
  6. WindowSettingsView (consumes 3 sub-sections)
  7. MenuBarContent (consumes BannerView callsites — replaced with LeafBanner inline)
  8. OnboardingView root coordinator (consumes 3 step views)
  9. Token preview migrations (LeafSheetLayoutPreview, LeafOnboardingStepLayoutPreview) — must precede LeafProminentButton/LeafSecondaryButton retirement
  10. Retirement: 8 file deletes + 1 dir delete + LeafType.swift comment refresh
  11. check-tokens.sh extension + self-test extension
  12. Final verification sweep

- **OQ-32: Tests baseline preservation.** D3 = 1213 tests. D4 — pure UI substrate, expect zero new tests. Verify baseline preserved.

- **OQ-33: Build schemes scope.** 5/5 xcodebuild schemes. LeafAgent / LeafCore / LeafCorePrivate / LeafMCP — не должны трогаться D4. Verify untouched (no source file changes outside `Leaf/`).

- **OQ-34: LeafMenuBarLayout vs LeafMenuBarLayoutTokens.width adjustment.** Current MenuBarContent uses 280pt; D1 token = 360pt. Could adjust D1 token к 280 (single-line tunable per token comment). **Decided:** adopt 360 per substrate. Reason: token discipline "substrate is source of truth"; if 360 surfaces UX issues post-ship, single-line tweak via token. 280 was magic number; 360 = considered substrate value.

- **OQ-35: Locale strings.** All new UI labels — English (D2/D3 precedent + product copy already English). Russian — only commits / spec / code comments.

## Glossary

- **D4-scope files** — files перечисленные в § "Scope > В D4" (19 files: 3 Sheets + 1 Org + 3 Settings + 1 Folders + 1 Profile + 1 RemovedBanner + 1 MenuBar + 4 Onboarding + 1 ShareTemplate + 2 Token previews + 2 scripts) + comment refresh в LeafType.swift. После D4 ship — все production view files на D1 substrate (zero old-palette refs); old palette files deleted.
- **D4 retirements** — 8 files deleted: `Leaf/Theme/{Colors,Fonts,GlassModifiers,CategoryColors}.swift` + `Leaf/Views/Window/Shared/{GlassCard,EmptyStateView,MetricCard}.swift` + `Leaf/Views/BannerView.swift` + `Leaf/Views/Window/Shared/` (empty dir).
- **Snapshot Replacement migration** (D1 § "Migration approach", carry-over) — D1 substrate ships без переезда existing views; D2/D3/D4 мигрируют свои views in-place. After D4: complete (no remaining views on old palette).
- **MIGRATION scope** — token-discipline guard tier inheriting BASE checks AND banning old-palette refs. After D4: `Leaf/Views/` (минус `Leaf/Views/Tokens/` BASE).
- **RETIRED tier** — D4-introduced third token-discipline tier banning old-palette names anywhere в `Leaf/`. Defense-in-depth (compile-time deletion is primary; RETIRED catches comments / strings / copy-paste).
- **Old palette / new palette** — old: `Leaf/Theme/{Colors,Fonts,GlassModifiers,CategoryColors}.swift` static extensions (Color.leafInk / Font.leafBody / .leafLabelStyle() / GlassCard / Color.leafCategory(_:) etc). New: D1 substrate (LeafColor / LeafType / LeafSpace / LeafCard / LeafButton / etc + leafSectionLabel() helper).
- **Forbidden combinations** — sheet-on-sheet glass material (LeafCard.glass inside LeafSheetLayout); LeafButton.ghost для destructive system Quit; LeafTab для property-setter (use Picker.segmented).
- **D4 substrate additivity** — D4 не добавляет новые D1 substrate components or T2 tokens (D2 added LeafStatusPillTokens.activeThresholdSeconds; D3 added LeafType.mono.large; D4 — pure consumer migration + retirement).

## Decision log

- **2026-05-10 / D4 spec — initial draft**
  - Stages 1-2 (Discovery + Brainstorm) complete; autonomous-decision mode (no user в loop).
  - 35 OQs decided with documented tradeoffs; key calls:
    - Sheets adopt LeafSheetLayout template (OQ-3, OQ-4, OQ-5).
    - Settings drop Form chrome universally (OQ-1, OQ-7, OQ-8, OQ-9, OQ-10).
    - MenuBarContent adopts LeafMenuBarLayout @ 360pt; quit stays native (OQ-2, OQ-16, OQ-17, OQ-18, OQ-19).
    - Onboarding inline migration, NOT LeafOnboardingStepLayout (popover constraint) (OQ-20, OQ-21).
    - Hard delete old palette files; compile-time enforce + RETIRED tier defense (OQ-22, OQ-23, OQ-24, OQ-25, OQ-26, OQ-27).
    - LeafMetricCard caption param NOT extended; ProfileView folds caption into title (OQ-13).
    - Folders Picker(.segmented) preserved для L4/L5 property-setter (OQ-11, OQ-9 ad-hoc folder row).
  - 19 file modifications + 8 file deletions + 1 dir delete + 1 comment refresh planned.
  - Token-discipline guard finalised: MIGRATION = whole Views/ minus Tokens/; RETIRED tier @ Leaf/.
  - Whitepaper sync deferred до Track 2 collective merge ship (OQ-29).
  - 5/5 xcodebuild schemes untouched outside `Leaf/`; 1213 SPM baseline preserved (zero new tests — D4 pure UI substrate).
