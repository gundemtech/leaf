# Track-7 P5 — Polish & acceptance gate · Design Spec

**Status.** Draft — Stage 3 of 8-stage phase workflow.
**Date.** 2026-05-17.
**Branch.** `feature/track-7-integration` off `main`.
**Authors.** Alex + Claude (brainstorm session 2026-05-17).
**Master design.** [`2026-05-17-track-7-ui-surface-polish-design.md`](2026-05-17-track-7-ui-surface-polish-design.md) §12 "P11 — Polish & acceptance gate" + §13 acceptance smoke + §14.2 whitepaper sync framing.

---

## §0 Phase position

P5 — финальная phase Track-7 после landed P1 (Foundation + Claude Code), P2-collapsed (Xcode + IDEs + Browsers + Zoom + Calendar), P3 (Work State), P4 (Layer B drill-downs). Все 4 siblings ветвятся off P1 head `90180348` и ждут collective merge в `main`. P5 = polish-минимум + acceptance gate + collective merge + whitepaper sync.

Не путать со старой нумерацией master spec'а: до v0.2 (2026-05-18 phasing rewrite) шла 11-phase раскладка где P11 был "Polish". В новой 5-phase раскладке (P1 / P2-collapsed / P3 / P8-collapsed→P4 / P11→P5) этот phase = P5.

---

## §1 Scope (one paragraph)

P5 создаёт `feature/track-7-integration` branch off `main`, sequentially мержит все 4 sibling branches (resolving единственный recurring conflict — `.claude/shared/current-state.md` text), накатывает ≤200 LOC polish-коммитов (ReauthBannerKeys hoist + spec amendments + HIG sweep fixes если нужны + token violations cleanup), прогоняет full §13 acceptance matrix (per-phase A-G × 4 + track-wide AC-1..AC-14 с RELAXED AC-13/AC-14), выполняет `/pre-push-leaf` checklist, делает collective `git merge --no-ff` в `main`, синкает whitepaper per §14.2 public-safe framing, обновляет `current-state.md`. После merge — 4 sibling branches архивируются read-only ~2 недели для post-merge audit окна.

**Substrate-only invariant РАСШИРЕН в P5.** Zero new event_kinds / migrations / MCP tools / schema columns + **ShareEventTypeKey registry frozen** (нет default-OFF → default-ON promotions). Verified в Step 10.

---

## §2 What's NOT in P5 (hard exclusion)

- **New features.** Никаких новых surface'ов, никакой новой бизнес-логики.
- **DEFERRED carry-overs (v1.1+).** Список из §3 D-3. Каждый сам по себе требует либо substrate change либо новый UX surface — не P5 polish scope.
- **Calendar GCP unblock work.** Calendar detail screen ships with `LeafEmptyState` placeholder + `[Connect]` CTA per OQ-T7-4. GCP setup (2-6 wk wall) — separate post-Track-7 track.
- **Localizable.strings extraction.** Per D-5 — relaxed AC-13. English hardcoded ships как known limitation, extraction = post-Track-7 localization track.
- **Instruments performance profiling.** Per D-6 — relaxed AC-14 до code-review verification через Stage 6 subagent.
- **Hover-only chevron refactor.** Per D-7 — always-visible chevron (P4 de facto) accepted, master spec OQ-T7-9 amendment в P5 spec instead.
- **OAuth scope expansions / new providers / cross-provider linked PR clickable navigation** — все v1.1.
- **Drag-and-drop card reorder, custom date-range picker, FTS search UI, cross-provider thread graph** — per master §14.

---

## §3 Decisions matrix

Каждое решение принято в Stage 2 brainstorm с явным rationale + user-approve gate.

| ID | Decision | Rationale | Impact |
|----|----------|-----------|--------|
| **D-1** | Integration branch strategy: `feature/track-7-integration` off `main`, sequential merge P1→P2-collapsed→P3→P4 (resolve `current-state.md` conflict each pass), polish commits на top, финальный `git merge --no-ff` в main | Single revert bubble; per-sibling history через --no-ff; conflict resolution в одном rebase passе, не дублируется | Stage 5 Steps 1-5 |
| **D-2** | Polish ship list (≤200 LOC budget): **(a)** ReauthBannerKeys hoist в `Leaf/Models/ReauthBannerKeys.swift` (~40 LOC, 3 sites), **(b)** OQ-T7-9 spec amendment (always-visible chevron — doc only), **(c)** Calendar empty-state copy review, **(d)** HIG sweep — 8 pending grep checks (fix только если broken), **(e)** `just check-tokens` 3-tier cleanup (ConnectionsView:199 — fix или widen waiver) | Min-scope unblock-the-merge polish. Каждый item — concrete known carry-over с защитимым ROI | Stage 5 Steps 7-9 |
| **D-3** | DEFER to v1.1: headline trend `<50% expected days` rule; real daily sparkline data; cross-provider clickable linked PRs → Linear issue; `ReviewActivityPeriod.last30Days` extension; clickable contextRef → LayerB drill-down; real-time D3 detector tick badge; sub-tab + range state restoration; empty-state "What's a Decision?" Whitepaper deep-link | Каждый требует substrate change (LeafCorePrivate SQL helpers) или новый UX surface — не polish scope. Defer не блокирует ship. | Out-of-scope tag в spec §2 |
| **D-4** | Calendar GCP gate: **still blocked**. P5 ships Calendar detail screen с `LeafEmptyState` placeholder + `[Connect]` CTA. No additional Calendar work in P5. | OQ-T7-4 resolution — placeholder UX = shipped state per P2-collapsed. GCP unblock = separate post-Track-7 track. | Stage 7 smoke verifies placeholder render |
| **D-5** | AC-13 Localizable.strings: **RELAX** для v1.0 — English hardcoded ships as known limitation. P5 spec documents this + post-Track-7 localization track placeholder. | Forcing `home.surface.*` / `home.work_state.*` / `detail.*` key extraction across ~9 detail screens = 200-300 LOC churn без user value pre-localization track. v1.0 is English-only ship anyway. | Documented в §10 Known limitations |
| **D-6** | AC-14 Performance: **RELAX** до code-review level. Stage 6 code-reviewer subagent verifies `@Observable` scoping per-surface; Instruments only if review surfaces подозрение. | Author time-budget; код-уровневая верификация достаточна для glance-surface (не hot render path). Glance surfaces refresh on app-foreground + occasional Settings toggle — не frame-rate-sensitive. | Stage 6 subagent prompt включает этот ask |
| **D-7** | OQ-T7-9 chevron — **accept always-visible** (de facto P4 shipped reality). Master spec OQ-T7-9 amendment в P5 spec: "Always-visible chevron supersedes hover-only resolution. Rationale: trackpad-only users + iOS-conventional discoverability cue." | Spec correction vs 20 LOC refactor — лучше документировать shipped behavior чем churn. P4 shipped reality стабильна, accept her. | Spec amendment в §11 OQ updates |
| **D-8** | Whitepaper sync scope per master §14.2: **SYNC** = new `surfaces/home-dashboard.md` (model: live state + Today aggregates + Work State derived + 9 surface drill-downs) **ИЛИ** extend existing `surfaces/native-app.md` (decide at Stage 8 based on file size) + `reference/changelog.md` entry per CLAUDE.md format. **WON'T SYNC** = SQL bodies, view-model SQL helpers, exact aggregate thresholds, headline formula details — все остаются в private modules. | Stays within public-safe framing. Pre-push-leaf checklist applies к leaf-docs sync (same moat rules). | Stage 8 Step 5 |
| **D-9** | Branch cleanup post-merge: 4 sibling branches **archived read-only** (NOT deleted) за 2 недели после merge для post-merge audit окна. `git push origin :feature/track-7-PN-*` deferred. | Forensic safety net — если post-merge regression surfaces, individual branch checkouts помогают bisect. | Stage 8 Step 8 (or skip) |
| **D-10** | Spec/plan placement: spec в `docs/superpowers/specs/2026-05-17-track-7-P5-polish-acceptance-gate.md` (committed to leaf repo). Plan в `docs/superpowers/plans/2026-05-17-track-7-P5-polish-acceptance-gate.md` (gitignored — implementation moat). | Per `conventions.md` Track-7 phase pattern. Plan = ephemeral implementation trace, spec = durable design document. | Stage 4 |

---

## §4 Integration branch creation + merge order (Stage 5 Steps 1-6)

### §4.1 Branch creation

```bash
git fetch --all --prune
git checkout main
git pull --ff-only
git checkout -b feature/track-7-integration
```

Integration branch starts at current `main` head (`3040c836` at spec-write time — may have moved if concurrent sessions pushed между Stage 1 Discovery и Stage 5 kickoff; not a problem).

### §4.2 Sequential merge order

**Critical: order matters for conflict resolution simplicity.** P1 merges first because it's the substrate root that the other 3 siblings each diverged from. P2-collapsed second (largest delta — 47 files). P3 third (medium — 26 files). P4 last (smallest — 18 files, doesn't touch most of what P2/P3 added).

```bash
# Step 2 — Merge P1 (substrate root)
git merge --no-ff origin/feature/track-7-P1-foundation-claude-code \
  -m "Merge feature/track-7-P1-foundation-claude-code into track-7-integration"
# Expected: no conflicts (P1 head 90180348 has docs commits only diverging from main — design spec + isEnabled lookup)

# Step 3 — Merge P2-collapsed
git merge --no-ff origin/feature/track-7-P2-collapsed-capture-surfaces \
  -m "Merge feature/track-7-P2-collapsed-capture-surfaces into track-7-integration"
# Expected conflict: .claude/shared/current-state.md (text reconcile)
# Resolution: KEEP P2's "Last update" header (most recent at merge time still wins;
#   но если будет cumulative-merge — combine: P5 added → P4 added → P3 added → P2 added → ... order)

# Step 4 — Merge P3
git merge --no-ff origin/feature/track-7-P3-work-state \
  -m "Merge feature/track-7-P3-work-state into track-7-integration"
# Expected conflict: .claude/shared/current-state.md
# Resolution: prepend P3 "Last update" header above P2's

# Step 5 — Merge P4
git merge --no-ff origin/feature/track-7-P4-layerb-drilldowns \
  -m "Merge feature/track-7-P4-layerb-drilldowns into track-7-integration"
# Expected conflict: .claude/shared/current-state.md
# Resolution: prepend P4 "Last update" header above P3's
```

**Conflict resolution rule for `.claude/shared/current-state.md`.** Each sibling препендит "Last update" header в начало файла. После 4 merges файл будет иметь 4 chronological entries (P1→P2→P3→P4 in reverse — newest first). Step 12 заменит все 4 entries единой Track-7 collective landing entry. **Не пытаться combine entries during merge** — keep them separate, чтобы можно было проверить целостность каждой phase'и; collapse в финальную form в Step 12.

### §4.3 Step 6 — Full build/test sweep

После merge всех 4 siblings — full validation на integration branch перед any polish work:

```bash
# 5 Xcode schemes
just build-all

# SPM full suite
cd Packages/LeafCore && swift test 2>&1 | tail -50
cd Packages/LeafCorePrivate && swift test 2>&1 | tail -50

# Test count delta vs main baseline
swift test 2>&1 | grep "Test Suite.*passed" | tail -1
# Expected: ≥2563 SPM tests (P4 baseline) + cumulative P1+P2+P3 net new
```

**Catch.** Cross-branch regression (P3 + P4 RouteCoordinator interaction, HomeView navigationDestination ordering, current-state.md cumulative drift). If regression detected → fix on integration branch via tactical TDD; document fix в Step 6 commit.

---

## §5 Polish commits (Stage 5 Steps 7-9)

### §5.1 Step 7 — ReauthBannerKeys hoist

**Current state.** 3 sites with hardcoded magic strings:
- `Leaf/Views/Window/Home/HomeView.swift:87` — `private static let reauthBannerDismissKey = "github.reauth.bannerDismissedSessionID"`
- `Leaf/Views/Window/Home/HomeView.swift:88` — `private static let slackReauthBannerDismissKey = "slack.reauth.bannerDismissedSessionID"`
- `Leaf/Models/LayerB/GitHubDetailViewModel.swift:59` — `private static let reauthBannerDismissKey = "github.reauth.bannerDismissedSessionID"`
- `Leaf/Models/LayerB/SlackDetailViewModel.swift:52` — `private static let reauthBannerDismissKey = "slack.reauth.bannerDismissedSessionID"`

Каждый site содержит comment "Mirror HomeView..." — manual reminder что strings shared. Risk: один из сайтов дрейфует, dismiss state desync'нется (банner в Home dismissed, в detail screen всё ещё показывается, или наоборот).

**Hoist design.** Новый файл `Leaf/Models/ReauthBannerKeys.swift`:

```swift
import Foundation

/// Per-launch dismiss state UserDefaults keys для GitHub / Slack OAuth scope drift banners.
/// Shared между `HomeView`, `GitHubDetailViewModel`, `SlackDetailViewModel` чтобы один dismiss
/// (в Home или detail) скрывал banner в обоих местах для current session. App restart →
/// новый AppSessionID → banner возвращается если scope still outdated.
public enum ReauthBannerKeys {
    public static let github = "github.reauth.bannerDismissedSessionID"
    public static let slack = "slack.reauth.bannerDismissedSessionID"

    /// Helper: read saved session-ID dismiss state for given provider.
    /// Returns `true` if user dismissed banner в current launch (saved == AppSessionID.current).
    public static func isDismissed(_ key: String) -> Bool {
        guard let saved = UserDefaults.standard.string(forKey: key) else { return false }
        return saved == AppSessionID.current
    }

    /// Helper: write current session-ID as dismiss marker.
    public static func markDismissed(_ key: String) {
        UserDefaults.standard.set(AppSessionID.current, forKey: key)
    }

    /// Helper: clear dismiss state (used когда scope refreshed и banner больше не needed).
    public static func clearDismissed(_ key: String) {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
```

**Refactor 3 sites:**

1. **HomeView.swift** — replace lines 87-88 + simplify lines 92, 98, 154, 177:
   ```swift
   // BEFORE: private static let reauthBannerDismissKey = "github.reauth.bannerDismissedSessionID"
   //         private static let slackReauthBannerDismissKey = "slack.reauth.bannerDismissedSessionID"
   //         let saved = UserDefaults.standard.string(forKey: Self.reauthBannerDismissKey)
   //         return saved == AppSessionID.current
   // AFTER:  (delete лишние statics)
   //         return ReauthBannerKeys.isDismissed(ReauthBannerKeys.github)
   ```

2. **GitHubDetailViewModel.swift** — replace lines 39-59 (the comment block + static + helper logic) с прямыми calls в `ReauthBannerKeys.isDismissed/.markDismissed/.clearDismissed(ReauthBannerKeys.github)`.

3. **SlackDetailViewModel.swift** — same pattern для `.slack`.

**Tests.** Add `Packages/LeafCoreTests/ReauthBannerKeysTests.swift` ✗ — **NOT в LeafCore**. `AppSessionID` lives в Leaf app target, not LeafCore. Tests должны быть в app-target test bundle. Spec proposal: add `LeafTests/Models/ReauthBannerKeysTests.swift` с 6 unit tests (read empty → false; mark + read → true; mark + clear + read → false; 2 keys независимы; both keys round-trip; AppSessionID change → previously-saved becomes false).

**Acceptance Step 7.**
- New file `Leaf/Models/ReauthBannerKeys.swift` compiles
- All 3 sites refactored — no more hardcoded strings outside `ReauthBannerKeys` enum
- New tests added (6 unit tests in LeafTests/Models/)
- `grep -rn "github.reauth.bannerDismissedSessionID\|slack.reauth.bannerDismissedSessionID" Leaf/ Packages/ --include="*.swift"` returns hits только в `ReauthBannerKeys.swift` + tests
- Build + tests green

### §5.2 Step 8 — HIG sweep grep matrix

Master spec §11 lists 13 HIG items. Discovery Part 6 marked 5 verified via P1 inheritance, 8 pending. Step 8 runs deep grep на integration branch для оставшихся 8.

**Grep matrix:**

| Item | grep command | Expected outcome | Fix if missing |
|------|--------------|------------------|----------------|
| 6. Hover affordance | `grep -rn "onHover" Leaf/Views/Window/Home/ Leaf/Views/Window/SurfaceDetail/` | Hits в SurfaceCard, LivePresenceWidget chevron-area | If 0 hits — confirmed P4 OQ-T7-9 always-visible chevron supersedes; no fix |
| 7. Keyboard nav (Tab/Return/Escape) | `grep -rn "keyboardShortcut\|onSubmit\|onExit" Leaf/Views/Window/Home/ Leaf/Views/Window/SurfaceDetail/` | NavigationStack defaults handle Escape pop; Tab/Return inherited from SwiftUI buttons | If broken (specific button doesn't respond) — add `.keyboardShortcut(.defaultAction)` to primary CTA |
| 8. Reduce Motion | `grep -rn "accessibilityReduceMotion" Leaf/Theme/ Leaf/Views/Window/Home/ Leaf/Views/Window/SurfaceDetail/` | Animations honor environment | If hardcoded spring без guard — wrap в `if reduceMotion { .none } else { .spring }` pattern |
| 9. Reduce Transparency | `grep -rn "accessibilityReduceTransparency" Leaf/Theme/` | LeafBanner / LeafCard glass surfaces guard | If hits = 0 AND we use glass (we don't on Track-7 cards per master §4.1) — no fix |
| 10. Dynamic Type | `grep -rn "LeafType.title.medium\|LeafType.body.regular\|LeafType.body.small" Leaf/Views/Window/Home/ Leaf/Views/Window/SurfaceDetail/` | Track-7 view files use LeafType tokens, не raw `.font(.system(...))` | If hits ≤ baseline + raw `.font` found — replace raw с LeafType |
| 11. Localizable.strings | `grep -rn "Text(\"" Leaf/Views/Window/Home/ Leaf/Views/Window/SurfaceDetail/ --include="*.swift" \| wc -l` | Hardcoded English strings count — DOCUMENT в Known limitations per D-5 | No fix per D-5 |
| 13. Accessibility labels | `grep -rn "accessibilityLabel\|accessibilityHint\|accessibilityAddTraits" Leaf/Views/Window/Home/ Leaf/Views/Window/SurfaceDetail/` | SurfaceCard, SurfaceRow, LivePresenceWidget columns, detail screen primary CTAs all have explicit labels | If missing — add per master §4.1 / §4.2 contract |

**HIG sweep policy.** Fix только если измеримый regression (broken behavior, не cosmetic). Otherwise document compliance status в §10 Known limitations. Goal — establish baseline, не perfect HIG compliance в одной фазе (Track-7 = first complete dashboard surface, HIG baseline = future polish target).

### §5.3 Step 9 — `just check-tokens` 3-tier cleanup

**Current baseline** (per P4 ship report): 1 inherited violation в `ConnectionsView.swift:199` — Google Calendar brand `Color(red: 0.18, green: 0.41, blue: 0.92)` inline literal. P2-collapsed waiver carried through к P4. Step 9 fixes или widens waiver.

**Fix path:**
1. Verify `BrandGoogleBlue` asset existence в `Leaf/Assets.xcassets/`:
   ```bash
   find Leaf/Assets.xcassets -name "BrandGoogleBlue*" 2>/dev/null
   ```
2. If asset exists → replace `Color(red: 0.18, green: 0.41, blue: 0.92)` с `Color("BrandGoogleBlue")` (or `LeafColor.brand.googleBlue` if exposed).
3. If asset absent → either create asset (color literal + name) OR widen waiver в `scripts/check-tokens.sh` exemption list с explicit comment "Google Calendar brand color — pending asset extraction".

**Acceptance Step 9.**
- `just check-tokens` exits clean (0 base violations, 0 migration violations, 0 retired violations beyond waiver)
- Если waiver widened — comment в `check-tokens.sh` объясняет почему

---

## §6 Stage 6 Independent code review (subagent)

After Steps 1-12 land on integration branch:

```
Agent(subagent_type=general-purpose, "code-reviewer mode"):
"Review feature/track-7-integration branch against master spec
docs/superpowers/specs/2026-05-17-track-7-ui-surface-polish-design.md
+ P5 spec. Key focus areas:

1. Substrate-only invariant — verify 0 event_kinds / migrations / MCP tools /
   ShareEventTypeKey delta vs main.
2. Cross-branch interaction correctness — RouteCoordinator merged push methods
   don't conflict; HomeView 3 navigationDestination registrations all wired;
   SurfaceCardState consistency across 9+1 surfaces.
3. @Observable scoping — per-surface ViewModels are isolated; no megaverse
   parent that re-emits на любое child change (AC-14 RELAX verification).
4. ReauthBannerKeys hoist correctness — 3 refactored sites + tests + grep clean.
5. Privacy walkback на full integration scope —
   grep -rE 'tool_input|tool_response|command|absolute_path|note_body|
   email_subject|file_contents|attendee_email|debugger_state|commit_message_body|
   attachment_body|review_body|message_text|preview' on
   Leaf/Views/Window/Home/ Leaf/Views/Window/SurfaceDetail/
   Leaf/Models/LayerB/ Leaf/Models/WorkState*
   Packages/LeafCore/Sources/LeafCore/Home/
   → must be 0 hits.
6. ReauthBannerKeys tests cover all 6 behaviors per spec §5.1.
7. Token cleanliness — `just check-tokens` exit 0 после Step 9.
8. HIG sweep compliance report — verify §5.2 grep matrix results match
   documented expectations.

Report: ACCEPT / ACCEPT-WITH-NITS / REJECT с per-finding category."
```

Main session applies `superpowers:receiving-code-review` skill для feedback digestion. Каждое finding адресуется (не "easy ones only"). REJECT → loop fix → re-review. ACCEPT-WITH-NITS → fix nits in additional polish commit, proceed.

---

## §7 Stage 7 Verification matrix

**§7.1 §13.1 Per-phase smoke (author's Mac, real data):**

| Phase | Smoke checks | Pass criteria |
|-------|--------------|---------------|
| P1 | A. Default Home renders 6 compact rows (none enabled). B. Enable Claude Code via Settings → Home updates ≤5s. C. Click Claude Code card → detail. D. Range tabs Today/Week/Month re-query. E. `[Enable]` deep-links к Settings → AI Tools. F. Today section shows files touched count. G. Back from detail preserves Home scroll. | All 7 pass; data updates visible |
| P2-collapsed | Per surface (Xcode / IDEs / Browsers / Zoom / Calendar) re-run A-G: compact row default → enable toggle → full card promote → tap → detail (range tabs) → back. Real-data signals: Xcode build → headline ≤1 tick; VSCode open workspace → IDEs workspace count +1; Browse 3 tabs allow-listed domain → Browsers page count +1, granularity respected; Zoom join+leave → "in calls" updates; Calendar `[Connect]` deep-links OAuth (GCP-blocked CTA visually). | 5 × 7 = 35 checks pass; placeholder visible for Calendar |
| P3 | A. Work State card visible (no toggle). B. With test fixtures: 3 open Qs + 1 blocker → headline renders. C. Click → detail. D. Sub-tab switching works. E. Zero-state shows "All clear". F. Resolved questions appear below open. G. ContextRef text "→ {ref}" rendered. | 7 pass; sub-tab transition smooth |
| P4 | Per provider (Linear / GitHub / Slack) re-run A-F: column shows chevron in title HStack → click → detail → range tabs → back preserves Home scroll. Aggregates section по spec §7.2. GitHub+Slack D: trigger scope drift → reauth warning banner. E: dismiss banner → stays dismissed for session. Linear: no scope drift case (skip D/E). F: privacy walkback grep returns 0 hits. | 3 providers × {Linear: 4, GitHub: 6, Slack: 6} = 16 checks pass |

**§7.2 §13.2 Track-wide AC-1..AC-14:**

| AC | Description | P5 status |
|----|-------------|-----------|
| AC-1 | Fresh install — 6 compact rows + Work State "All clear" + LivePresence "Connect" CTAs; no dead pixels | Smoke verified |
| AC-2 | All capture surfaces enabled + 3 OAuths — 6 full cards + 3 LivePresence + Work State populated; fits 1100×720 без horizontal overflow | Smoke verified |
| AC-3 | Mid-state — enabled cards top, disabled rows below; ordering matches `HomeSurface.allCases` per partition | Smoke verified |
| AC-4 | Detail screen navigation — 9 reachable, Today/Week/Month re-query ≤500ms, recent events ≤50 rows | Smoke verified + Instruments-light spot check |
| AC-5 | Privacy walkback grep — 0 hits forbidden fields в new Track-7 file scope | Step 11 automated grep |
| AC-6 | `just check-tokens` — 3-tier clean | Step 9 verified |
| AC-7 | `xcodebuild` 5/5 schemes (Leaf/LeafAgent/LeafMCP/LeafCore/LeafCorePrivate) green | Step 6 build sweep |
| AC-8 | SPM full suite + new Track-7 unit tests pass | Step 6 test sweep |
| AC-9 | VoiceOver reads each card per §11 contract | Smoke spot check |
| AC-10 | Reduce Motion ON: range tab opacity-only transitions; spark renders без redraw animation | Spot check |
| AC-11 | Reduce Transparency ON: glass surfaces (none expected на cards) fallback к solid | Spot check |
| AC-12 | Dynamic Type Largest: card text wraps 2 lines max + truncates; compact rows не overlap | Spot check |
| AC-13 | Localizable.strings — all new strings keyed `home.surface.*` / `home.work_state.*` / `detail.*` | **RELAXED per D-5** — documented as known limitation |
| AC-14 | Performance — capture toggle ≤1 SurfacesSection re-render; Instruments verified no excessive body evaluations | **RELAXED per D-6** — Stage 6 subagent code-review verifies @Observable scoping |

**§7.3 Test count target.**
- Baseline P4 ship report: **2563 SPM tests**
- P5 net new: 6 (ReauthBannerKeys) + 0 elsewhere = **≥2569 SPM target**
- Acceptance: actual ≥ baseline + 5 (allowing 1-test margin для refactor adjustments)

**§7.4 Stop-ship conditions.**
- Any per-phase smoke check fails AND fix > 1 hour scope → escalate, не ship
- AC-5 privacy walkback fails → STOP, audit, никакого ship
- AC-6 token violations new beyond waiver → STOP, fix
- AC-7 build red → STOP, fix
- AC-8 tests red → STOP, fix
- AC-9/10/11/12 spot check broken → fix-bundle commit, re-run

---

## §8 Stage 8 Ship plan

### §8.1 Pre-flight

```bash
# 1. Verify integration branch state
git status  # clean
git log --oneline main..HEAD | head -20  # all polish commits visible

# 2. Pre-push checklist для public leaf repo
# (manual run of /pre-push-leaf checklist на full integration diff vs main)
```

### §8.2 Merge

```bash
# 3. Pull latest main (catch concurrent infra commits)
git checkout main
git pull --ff-only

# 4. Merge integration → main (single bubble через --no-ff)
git merge --no-ff feature/track-7-integration \
  -m "Track-7 (Home dashboard surface) landed — collective merge

Includes:
- P1: Foundation + Claude Code surface + SurfaceCard / SurfaceDetailLayout / SurfaceRow primitives
- P2-collapsed: 5 capture surface cards (Xcode / IDEs / Browsers / Zoom / Calendar)
- P3: Work State card + detail (D3 detection surface)
- P4: Layer B drill-downs (Linear / GitHub / Slack)
- P5 polish: ReauthBannerKeys hoist + HIG sweep + token cleanup

Substrate-only invariant: 0 new event_kinds / migrations / MCP tools / schema columns / ShareEventTypeKey delta.
Whitepaper sync: see leaf-docs/surfaces/ + reference/changelog.md."

# 5. Push to origin
git push origin main
```

### §8.3 Whitepaper sync

```bash
cd ~/Desktop/Leaf/leaf-docs
git pull --ff-only --quiet

# 6. Update or create home dashboard surface description
# Decision at Stage 8: extend surfaces/native-app.md (if file is <300 lines) OR
#   create surfaces/home-dashboard.md (if native-app.md is already large)
# Content: dashboard model = live state + Today aggregates + Work State derived +
#   per-surface drill-downs (9 surfaces); philosophy = "glance-useful без AI client";
#   public-safe framing per master §14.2 — никаких SQL bodies, thresholds, formula
#   details. Reference master spec §3 (Home layout) + §4 (Surface card contract) +
#   §6 (Work State) + §7 (Layer B drill-downs) for content scaffold.

# 7. Add admonition block
# !!! note "Изменение vX.Y — 2026-05-XX"
#     Раньше: Native UI шипила hero + LivePresenceWidget + Today + Recent Sessions.
#     Теперь: + Work State card (D3 surfaces) + Surfaces section (9 drill-down cards
#       — 6 Track-6 capture surfaces + 3 Layer B providers) + LivePresenceWidget columns
#       tappable per provider.
#     Причина: Track-7 P1-P5 collective landing — bring UI surface to capture depth shipped
#       through alpha.16.

# 8. Append changelog entry per CLAUDE.md format
# Format: - **YYYY-MM-DD HH:MM · Alex** — Track-7 (Home dashboard surface) landed:
#   {one-line summary}. {brief impact}.

# 9. Commit + push leaf-docs
git add docs/surfaces/<file> docs/reference/changelog.md
git commit -m "docs: Track-7 (Home dashboard surface) landed"
git push origin main
```

### §8.4 Post-ship

```bash
# 10. Update .claude/shared/current-state.md в leaf repo с финальной Track-7 landed entry
# (Replaces 4 cumulative per-phase entries с одной collective entry)

# 11. Final sanity check
git log --oneline main -5
git -C ~/Desktop/Leaf/leaf-docs log --oneline main -3

# 12. Branch cleanup decision (D-9)
# Recommended: archive 4 sibling branches read-only ~2 weeks
# - DO NOT git push origin :feature/track-7-PN-* yet
# - Add reminder в ~/.claude/projects/ memory if used
```

---

## §9 Risks / mitigations

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Concurrent session (970399ad / 3b96c383) pushes to P4 branch после Stage 1 snapshot, shifting head | Medium | Step 1 включает `git fetch --all --prune` снова; rebuild snapshot если P4 head moved beyond `569a4830`. Concurrent sessions = lint cleanup on P4 — likely safe-pure-refactors, не feature changes. |
| Cross-branch regression обнаруживается в Step 6 build/test sweep | Medium | Stop-ship gate Step 7.4; fix on integration branch via TDD; document fix commit; re-run Step 6 |
| `current-state.md` text reconcile creates cumulative bloat that confuses future readers | Low | Step 12 collapses 4 entries в single Track-7 collective entry. Audit trail сохраняется через git log/blame on each P1/P2/P3/P4 entry sources. |
| `just check-tokens` finds new violations beyond ConnectionsView:199 baseline waiver | Low | Step 9 inspects new violations; either fix in-place или widen waiver с explicit comment |
| ReauthBannerKeys hoist breaks existing dismiss UX (Self.reauthBannerDismissKey → ReauthBannerKeys.github) | Low | New tests cover 6 behaviors; manual smoke в Stage 7 P4 D/E checks banner dismiss state |
| Stage 6 subagent rejects ACCEPT-WITH-NITS → нужны loop fixes | Medium | Standard pattern; budget +1 fix-bundle commit per nit category |
| Whitepaper sync leaks moat detail (SQL formula, threshold value) | Low | Pre-sync manual review applies same /pre-push-leaf moat rules. Не sync anything outside listed scope D-8. |
| Calendar GCP gate clears unexpectedly between spec-write и ship (positive surprise) | Low | Doesn't block P5 — Calendar placeholder ships either way. GCP unblock = separate post-Track-7 ship coordinated with Connections team. |
| Active session 3b96c383 currently doing "Stage 0 — Setup worktree off origin/main" — может быть параллельно interfering | Medium | Worktree isolation should protect; before Step 1 — verify no conflicting commits на main. If concurrent session lands meaningful commit на main между Stage 1 Discovery и Stage 5 kickoff — rebase integration branch onto new main HEAD. |
| Test count drops below baseline (regression detected) | Low | Step 6 catches; investigate which sibling's tests didn't make integration; fix-merge required |

---

## §10 Known limitations (post-ship debt)

1. **AC-13 Localizable.strings — RELAXED.** All new view files contain English hardcoded text strings. Extraction в `home.surface.*` / `home.work_state.*` / `detail.*` keys = post-Track-7 localization track. Estimated effort: 200-300 LOC + 1 day. Trigger: when first non-English-speaking pilot user enters program OR when v1.1 Localizable.strings infra track kicks off (whichever earlier).
2. **AC-14 Performance — code-review level only.** Instruments profiling deferred. Stage 6 subagent verified @Observable scoping per-surface; no measured frame timing or body-call counts. Trigger for Instruments run: any user report of UI jank или Settings toggle latency > 1s perceived.
3. **Calendar GCP gate still blocked.** Calendar detail screen ships as placeholder with `LeafEmptyState` + `[Connect]` CTA. Real Calendar data flow blocked on GCP project + brand verification + sensitive scope approval (2-6 wk wall). Post-Track-7 track owns GCP setup.
4. **OQ-T7-9 chevron amendment.** Master spec §15 OQ-T7-9 resolved as "hover only". P5 supersedes: always-visible chevron (P4 de facto shipped reality). Rationale: trackpad-only users + iOS-conventional discoverability. Master spec needs amendment commit (separate doc-only commit либо bundle с whitepaper sync).
5. **DEFERRED v1.1 carry-overs (per D-3).** 8 items: headline trend `<50% expected days` rule; real daily sparkline data (LeafCorePrivate SQL helpers); cross-provider clickable linked PRs → Linear; `ReviewActivityPeriod.last30Days` extension; clickable contextRef → LayerB drill-down; real-time D3 detector tick badge; sub-tab + range state restoration; empty-state "What's a Decision?" Whitepaper links.
6. **P2-collapsed Phase E (Prod insights SQL helpers) deferred.** ProdBrowsersActivitySQL / ProdGoogleCalendarActivitySQL / ProdIDEsActivitySQL / ProdXcodeActivitySQL / ProdZoomActivitySQL — currently stubs/empty returning empty data. Real numbers light up when LeafCorePrivate gets concrete SQL implementations against substrate (currently in main from Track-6 P1-P7). Post-Track-7 work, не P5 scope.
7. **HIG full compliance baseline — partial.** §5.2 sweep establishes baseline; не perfect compliance в одной фазе. Specific gaps documented per grep matrix outcomes (will be captured в commit message of Step 8).
8. **WorkStateHeadlineFormatter не hoisted.** Discovery подтвердил — formatter не существует в P3 (inline composition в WorkStateCardViewModel). No hoist needed. P3 spec carry-over "WorkStateHeadlineFormatter hoist" — outdated note, deferred indefinitely.

---

## §11 Open questions / spec amendments

| ID | Question / Amendment | Status |
|----|----------------------|--------|
| OQ-P5-1 | Whitepaper sync target: extend `surfaces/native-app.md` vs create `surfaces/home-dashboard.md`? | **Decide at Stage 8** based on `native-app.md` current size. < 300 lines → extend; ≥ 300 → new file. |
| OQ-P5-2 | Branch cleanup timing — archive 2 weeks vs delete immediately? | **Resolved: archive 2 weeks** per D-9. Forensic audit window. |
| OQ-P5-3 | Master spec OQ-T7-9 chevron amendment — separate doc-only commit или bundled with whitepaper sync? | **Resolved: bundled.** Single Track-7 collective ship → 1 master spec amendment commit either в leaf repo (master spec lives in leaf repo) либо как docs/superpowers/specs amendment. Bundle with leaf-side ship commit. |
| OQ-P5-4 | If Stage 6 subagent ACCEPT-WITH-NITS surfaces gap NOT covered в §5 polish list (e.g. accessibility hint missing на 5 buttons) — fix в P5 или defer? | **Resolved heuristic:** fix только если ≤ 30 LOC per fix-bundle, иначе defer + document. Budget guardrail: total polish (Steps 7-9 + Stage 6 fixes) ≤ 300 LOC. |
| OQ-P5-5 | If Stage 7 P3 smoke depends on D3 detector test fixtures (3 open Qs + 1 blocker), какие fixtures use? | **Open.** Either (a) generate via running detectors against synthetic test events; (b) inline test fixtures в WorkStateCardViewModel debug mode; (c) skip P3 detail smoke с note "requires fixture data". Recommended (c) для P5 — fixture-generation = scope creep. |
| OQ-P5-6 | Active sessions 970399ad / 3b96c383 on P4 branch — do they affect P5? | **Mitigated:** Step 1 fetch verifies P4 head; if shifted, rebuild snapshot. Concurrent sessions = lint cleanup, low-risk for Track-7 collective merge. |

---

## §12 Acceptance gate для P5 (что считается "Track-7 cleared")

После Stage 8 ship:

- ✅ `main` updated с single `Track-7 (Home dashboard surface) landed — collective merge` commit
- ✅ All Stage 7 §13.1 per-phase smoke checks passed (4 phases × 5-7 checks each)
- ✅ All Stage 7 §13.2 AC-1..AC-12 passed (AC-13/AC-14 RELAXED, documented)
- ✅ Stage 6 code-reviewer subagent ACCEPT (или ACCEPT-WITH-NITS fixed)
- ✅ Substrate-only invariant verified — diff `main` vs pre-merge baseline shows 0 schema/event_kind/MCP/ShareEventTypeKey delta
- ✅ Privacy walkback grep AC-5 — 0 hits
- ✅ `just check-tokens` 3-tier clean
- ✅ Whitepaper sync committed + pushed в gundemtech/leaf-docs (1 new или extended `surfaces/*.md` + `reference/changelog.md` entry)
- ✅ `.claude/shared/current-state.md` updated с Track-7 collective landed entry
- ✅ 4 sibling branches archived read-only (или deleted, per D-9 final decision)

---

## §13 Implementation order (Stage 5 Steps 1-12)

```
Step 1 — Branch creation
  git checkout -b feature/track-7-integration (off main)

Step 2 — Merge P1 (no conflicts expected)
Step 3 — Merge P2-collapsed (resolve current-state.md text)
Step 4 — Merge P3 (resolve current-state.md text)
Step 5 — Merge P4 (resolve current-state.md text)

Step 6 — Full build/test sweep
  - 5 xcodebuild schemes
  - SPM full suite
  - Test count delta vs baseline
  - Fix any cross-branch regressions

Step 7 — ReauthBannerKeys hoist (TDD)
  - Write Leaf/Models/ReauthBannerKeys.swift
  - Write LeafTests/Models/ReauthBannerKeysTests.swift (6 tests)
  - Refactor HomeView + GitHubDetailViewModel + SlackDetailViewModel
  - grep clean verify

Step 8 — HIG sweep grep matrix (8 pending items)
  - Run grep matrix per §5.2
  - Fix only if measurable regression
  - Document compliance status

Step 9 — `just check-tokens` cleanup
  - Verify BrandGoogleBlue asset / fix ConnectionsView:199
  - Or widen waiver с comment

Step 10 — Substrate-only invariant verification
  - git diff main..HEAD на ShareEventTypeKey / migrations / MCP / event_kinds

Step 11 — Privacy walkback grep AC-5 (full integration scope)

Step 12 — current-state.md collapse + final commit
  - Replace 4 cumulative per-phase entries with single Track-7 collective entry
  - Final commit с подробным message + acceptance gate snapshot
```

---

## §14 File deltas summary (post-merge integration branch vs main)

| File category | Count | Source phases |
|---------------|-------|---------------|
| New LeafCore types (Home/, Insights/, Sharing/) | ~45 | P1 (4) + P2-collapsed (28) + P3 (9) + P4 (4) |
| New Leaf views (Window/Home/, Window/SurfaceDetail/, Theme/) | ~18 | P1 (4) + P2-collapsed (5) + P3 (2) + P4 (3) + Layouts (4 shared modified) |
| New Leaf ViewModels (Models/, Models/LayerB/) | ~15 | P1 (1) + P2-collapsed (5) + P3 (2) + P4 (3) + RouteCoordinator modified |
| New tests (LeafCoreTests/, LeafTests/) | ~30 | P1 (6) + P2-collapsed (7) + P3 (5) + P4 (5) + P5 (6 ReauthBannerKeys) |
| P5 polish-only deltas | ≤200 LOC total | ReauthBannerKeys (~40) + HIG fixes (up to ~50) + ConnectionsView fix (~5) + spec amendments (doc-only) |

**Substrate-only verification expected outputs:**
```bash
# All should return 0 (or only doc / test changes)
git diff main..HEAD -- Packages/LeafCore/Sources/LeafCore/Sharing/ShareEventTypeKey.swift | wc -l
git diff main..HEAD -- Packages/LeafCore/Sources/LeafCore/DB/Migrations/ | wc -l
git diff main..HEAD -- Packages/LeafMCPServer/ | wc -l
git diff main..HEAD -- Packages/LeafCore/Sources/LeafCore/Models/RawEvent.swift | wc -l
```

---

*End of spec.*
