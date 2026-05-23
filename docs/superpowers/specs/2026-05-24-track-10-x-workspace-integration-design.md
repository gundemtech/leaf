# Track-10 × Workspace-Redesign Integration — Design Spec

**Date**: 2026-05-24
**Owner**: Дима (Claude assists)
**Status**: Design draft — pending Дима's approval gate (CTO adversarial pass applied inline)
**Reviewed-By**: Claude CTO adversarial pass 2026-05-24 — 5 CRITICAL + 6 HIGH findings inline-fixed
**Sessions**: Спроектировано как 4-phase multi-session track (Phase I..IV.B). Phase IV split into IV.A (UI cherry-pick) + IV.B (Workspace rewire) — committed from start.

---

## 1 — Context

Две ветки разошлись от common ancestor `8d2d2d70 docs(specs): Track 5 collaboration redesign contract (draft)`:

| Ветка | Commits since base | Files changed | What it added |
|---|---|---|---|
| `origin/feature/invite-redesign` (partner) | 252 | 398 | Track-5 / S1..S8 (Supabase + Multi-Workspace + DM + Tier + Realtime + APNs + `leaf_query_team` MCP) + Invite System Redesign (M027 invite_tokens + join_requests + 6 Edge Functions) + M-tier perf isolation series |
| `feature/track-10-operational-home` (мы) | 273 | 861 | Track-6 P1..P7 (capture depth) + Track-7 / Track-8 substrate + Track-9 T1..T10 (substrate enrichment) + Track-10 T1..T9 (operational Home redesign) |

**Overlap**: 84 файла. Большинство — shared infra (Schema, Database, MCPServer, HomeView, RootView, OAuth services, Settings sub-sections), где обе ветки независимо эволюционировали.

**Архитектурное направление** (решено в brainstorm): partner-branch стек выигрывает. Track-5 multi-workspace + Supabase + Invite Redesign — forward architectural direction. Track-10 адаптируется под `WorkspaceReader` / `ActiveWorkspaceStore`. Phase 5.1-5.6 substrate отбрасывается как superseded.

**Подход**: phase-by-phase, integration branch off partner's HEAD, sync per phase boundary.

---

## 2 — Integration branch lifecycle

- **Name**: `feature/integration-track-10-x-workspace-redesign`
- **Base point**: `origin/feature/invite-redesign` HEAD snapshot at start of Phase I. Конкретный commit hash зафиксировать в Phase I session log.
- **End goal**: после прохождения 4 phases + acceptance gate — `git push origin integration/...:dev`; затем отдельной сессией `dev → main` через PR с `--no-ff` merge.
- **Visibility**: после Phase I push в `origin` (`feature/integration-track-10-x-workspace-redesign`) для transparency — partner видит progress.
- **Commit prefix**: `feat(integration-T10): ...` / `chore(integration-T10): ...` / `docs(integration-T10): ...` / `test(integration-T10): ...`
- **partner's branch не трогаем destructively** — `feature/invite-redesign` остаётся под его управлением. Только pull, никаких push'ей со стороны integration.

---

## 3 — Sync cadence

Перед началом каждой новой phase-сессии:

```bash
cd ~/Desktop/Leaf/leaf
git fetch --all --prune
git checkout feature/integration-track-10-x-workspace-redesign
git merge origin/feature/invite-redesign --no-ff -m "chore(integration-T10): sync partner's HEAD before Phase <N>"
# Resolve conflicts if any. Если sync brings semantic break — separate fix-bundle commit как Stage 0 phase.
```

Phase boundaries = natural sync points. Внутри одной phase больше не sync'аем — partner's intermediate commits ловим в следующей phase.

---

## 4 — Phase decomposition

### Phase I — Baseline + Schema reconcile

**Goal**: подготовить integration branch для cherry-pick'ов. Никакого нашего кода ещё не add'нуто.

**Tasks**:
1. `git checkout -b feature/integration-track-10-x-workspace-redesign origin/feature/invite-redesign`. Зафиксировать base commit в этом spec'е по итогу.
2. **Schema reconciliation** — наши Track-6 P1/P3/P4 migrations renumber:
   - Track-6 P1 `idx_events_ai_subagent` partial index: M024 → **M028**
   - Track-6 P3 domain allow-list: M026 → **M029**
   - Track-6 P4 gcal_sync_tracker: M027 → **M030** (но Phase II defer'ит P4 целиком — M030 не материализуется в integration пока)
   - Update `Packages/LeafCore/Sources/LeafCore/DB/Migrations/` filenames и `Database.swift` registry sequence.
   - Update test fixtures которые ссылаются на конкретные M-номера.
3. **partner's Track-1..-4 substrate audit**: diff наши версии Track-1 D2 (`events_fts`, `event_links`, M012/M013) и Track-1 D3 (`decisions` / `open_questions` / `blockers` / `where_stopped_log` / `detector_offsets`, M014) против partner-branch версий. Если drift — fix-bundle commit как часть Phase I.
4. **LeafCorePrivate moat coordination** — **AMENDED 2026-05-24 Phase I (inversion-resolved)**:
   - Original assumption: partner-branch `LeafCorePrivate/Prod/` references (`ProdSlackChannelsProvider`, `ProdLinearTeamsProvider`, `fetchAccessibleUsers`, и т.д.) missing on clean clone → нужны mock stubs.
   - **Actual observation (Phase I execution)**: situation is **bilateral**, not unilateral. Each developer has own `LeafCorePrivate/Prod/` locally (gitignored). When мы check out integration branch off partner's HEAD:
     - Our local `Prod/` (73 .swift) persists across checkout (gitignored) — references our T10 Track-6 types absent in partner's LeafCore → compile errors из НАШЕГО moat.
     - Our local `LeafCorePrivateTests/` (74 .swift) same situation.
     - Our local `Config/Local.xcconfig` `LEAF_FLAGS = LEAF_PROD` keeps app targets calling partner's missing `ProdConfigs` / `prodDetectorMoat` symbols inside `#if LEAF_PROD` блоков.
   - **Phase I resolution**: stash own Prod/ + LeafCorePrivateTests/ aside to `~/Desktop/Leaf/leaf-integration-prod-stash/`; toggle `LEAF_FLAGS =` empty в Local.xcconfig. См. **Section 16 — Stash protocol** ниже.
   - **No MockProviders stubs created**: not needed once stash + flag toggle done. Production ship (post-Phase IV merge) requires real partner prod files via private channel.
5. **CI baseline**: локально 5/5 xcodebuild schemes green; ~2155 SPM tests + partner-branch pgTAP files pass; `pre-push-leaf` clean. GitHub Actions integration branch enabled (если CI workflows есть в partner's branch для integration/* pattern).
6. **Early-commit M028/M029 names**: commit naming Migrations file rename + Schema registry sequence rebase **в first commit Phase I** — sync collisions на M028/M029 далее ловятся как syntax/textual conflicts, не как semantic schema drift.

**Acceptance**: clean checkout builds, tests pass, schema migrations sequence корректна, готовы к Phase II cherry-pick'ам.

### Phase II — Track-6 substrate

**Goal**: layer наш Track-6 capture-depth substrate поверх partner-branch baseline.

**Cherry-pick scope**:
- Track-6 P1 — Claude Code Deep: +14 `claude_*` event_kinds + subagent capture + hook bridge socket + jsonl floor + M028 partial index.
- Track-6 P3 — Browsers Deep: +8 event_kinds + AppleScript Safari/Chrome/Arc + M029 domain allow-list.
- Track-6 P2 — Xcode Deep: +6 event_kinds + xcresult parser + DerivedData FSEvents.
- Track-6 P5 — Zoom Deep: +3 event_kinds + EventKit cross-link.
- Track-6 P6 — IDEs Surface Cap: +4 event_kinds + VSCode-family parser + JetBrains FSEvents.
- Track-6 P7 — GPT Cap doc-only.

**Defer**:
- **Track-6 P4 — GoogleCalendar Deep**: blocked on GCP setup gate (2-6 wk wall); дополнительно теперь в semantic clash с partner-branch Supabase OAuth flow. Carry-over под partner-branch tier-gate как post-integration follow-up.

**Approach**: cherry-pick по логическим pre-bundle'ам Track-6, не отдельным commit'ам. Каждая sub-phase II.<N> = один cherry-pick set + tests pass + sentinel-injection regression.

**Acceptance**: registry expand с partner-branch 152 → ~195 ShareEventTypeKey (с учётом, что Track-6 substrate landed). Track-6 sentinel-injection tests pass. Privacy walkback grep по 12 forbidden patterns → 0 hits.

### Phase III — Track-8 P1 substrate + Track-9 T1..T10 enrichment

**Goal**: substrate для Track-10 zones. UI surfaces из Track-7/Track-8 явно skip — superseded Track-10.

**Skip**:
- Track-7 P1..P5 — 9 drill-down cards + Work State card. Все superseded Track-10 zones. **Не cherry-pick'аем**.
- Track-8 P2..P9 — per-pillar UI surfaces (TODAY full block, YOU·NOW full block, WITH YOU full block, INBOX, WHERE STOPPED). Superseded Track-10 compact zones. **Не cherry-pick'аем**.

**Cherry-pick**:
- Track-8 P1 substrate — 6 pillars stubs (`TodayMetrics`, `YouNowState`, `InboxItem`, `WeeklyMetrics`, `WhereStoppedSnapshot`, etc readers + composers).
- Track-9 T1..T10 substrate enrichment — registry 195 → 198 (+3 event_kinds via payload field enrichments), no migrations, cross-provider pulse derivers, standup substrate enabling Track-10 RECAP/EOD.

**Workspace-readiness review**: каждый reader/deriver проверить на `OrgReader` dependency. Если есть — временный stub возвращает first workspace (Phase IV правильный rewire на `ActiveWorkspaceStore.activeWorkspaceID`).

**Acceptance**: substrate готов surface'иться Track-10. ~198 event_kinds в registry. Tests pass. Substrate-purity preserved (Phase 8.1 + Track-9 design discipline).

### Phase IV — Track-10 UI + Workspace rewire (split into IV.A + IV.B from start)

**Goal**: ship Track-10 operational Home поверх multi-workspace substrate. **Committed split** на IV.A (UI cherry-pick) + IV.B (Workspace rewire) — два отдельных sessions по `conventions.md` discipline.

#### IV.A — Track-10 UI cherry-pick:
- T2 — RESUME hero (Zone-1 + `GitDeltaReader` substrate + `ResumeHeroBlock`).
- T3 — YOU·NOW state badge inline (`YouNowStateBadge` 5-state capsule).
- T4 — NEEDS YOU rename + `InboxFilter.actionable` default.
- T5 — SINCE YOU WERE LAST ACTIVE (14-kind activity feed since `lastSeenAtMs`).
- T6 — TEAM·N broader pulse (Zone-3 swap from narrow WithYouOnThisBlock).
- T7 — YOU'RE ON anchor (Zone-4 `CurrentTaskSession` + HomeContent extraction).
- T8 — RECAP/EOD standup collapsibles (`StandupComposer` over T5 feed × 2 windows + Phase 8.3 metrics + D3 blockers).
- T9 — polish sweep (a11y + HIG + perf).
- T1 — foundation (Analytics hide + onboarding share-controls preset).
- T2.5 — post-T3 bug-fix bundle.
- **Onboarding graft**: T1 share-controls preset addition надо вшить в **partner-branch** Onboarding (его `.team` step superseded наш). Extract preset injection как stable pure function в `LeafCore`, вызвать из его Onboarding lifecycle.

#### IV.B — Workspace rewire:
- Replace `OrgReader` calls → `WorkspaceReader` + `ActiveWorkspaceStore` в Track-10 surfaces:
  - `Leaf/Views/Window/Home/HomeView.swift` (новый HomeContent extraction)
  - `Leaf/Views/Window/RootView.swift`
  - `Leaf/Views/Window/Sidebar.swift` (минимально — partner's Sidebar уже импортирует `WorkspaceReader` + `ActiveWorkspaceStore` + `LeafWorkspaceSwitcher`; наш rewire только если Track-10 добавил sidebar rows)
  - `Leaf/Views/Window/Organization/OrganizationView.swift`
  - `Leaf/Models/WindowState.swift` (active-workspace context).
- Drop Phase 5.5/5.6 substrate Track-10 references:
  - `PendingInvitesStore` callsites — replace with partner-branch `InviteTokenService` / `JoinRequestService`.
  - `MemberRemovalReader` + `RemovedFromTeamBanner` callsites — replace with partner's JoinRequest decline/leave path.
  - `Leaf/AppLifecycle/InviteURLHandler.swift` — adapt to Magic-Link URL format (partner's `leaf://invite/<22>?w=&a=`).
- **Workspace switcher уже implement'нут partner** (`LeafWorkspaceSwitcher` в Sidebar bottom, Track 5 / S7 G.12). НЕ добавляем — только consume его store.
- **`M010_PendingInvites` table preserve в schema** (partner сохранил для migration safety). Удалить только наш UI код, не миграцию.

**Per-zone workspace-aware behaviour** (см. Section 6 ниже).

**Acceptance**:
- Track-10 zones показывают active-workspace context корректно.
- Workspace switcher работает.
- Все partner's Track-5 / Invite-Redesign acceptance gates всё ещё pass (G1-G22 still green).
- Все Track-10 visual smoke pass (mockup parity per master spec §7.3).
- 5/5 xcodebuild schemes green.
- ~2550+ SPM tests pass.
- Privacy walkback grep clean.

---

## 5 — Disposal list (что отбрасывается из нашей T10 branch)

| Component | Why dropped | Replacement |
|---|---|---|
| `LeafCore/Team/OrgService.swift` (если ещё в наш T10) | partner удалил в Track-5/S2 Task 12 | `WorkspaceService` |
| `Leaf/Models/OrgReader.swift` | deleted by partner | `WorkspaceReader` + `ActiveWorkspaceStore` |
| `Leaf/Models/MemberRemovalReader.swift` + `RemovedFromTeamBanner.swift` | superseded by JoinRequest decline | `JoinRequestService` decline/leave callbacks |
| `Phase 5.5 PendingInvitesStore` + `PendingInviteRow` UI + `M010 pending_invites` | superseded by partner's Magic-Link + JoinRequest | `invite_tokens` (partner's M027) + `join_requests` |
| `LeafCore/URLScheme/InviteURL` blob format (Phase 5.2 plain invite-blob) | superseded by Magic-Link | partner's URL scheme `leaf://invite/<22>?w=&a=[#otp]` |
| `Phase 5.1 EnvelopeCodec` plain DO relay path | superseded by Supabase Realtime + APNs | partner's `EncryptedRow` + Realtime substrate |
| `leaf-relay` Cloudflare Worker (private repo) | superseded by Supabase Edge Functions | Deprecated; keep repo for archive |
| **Phase 5.4 broadcast WS substrate** (наш own future track) | НЕ было в Track-10. Не тащим. | Future Phase 5.4-v2 на Supabase Realtime — отдельный track |
| Track-7 P1..P5 UI surfaces (9 drill-down cards + Work State card) | superseded by Track-10 zones | Track-10 T2/T3/T4/T6/T7 |
| Track-8 P2..P9 UI surfaces (full per-pillar blocks) | superseded by Track-10 compact zones | Same Track-10 zones |

---

## 6 — Track-10 zones × Multi-workspace context mapping

**Resolved**: partner's M019 НЕ partitionирует `events` table. Он rename'нул `org → workspaces` + добавил `workspace_id` columns в **только team-related таблицы**: `team_members`, `team_keys`, `rotation_outbox`, `pending_invites`. Events остаются device-wide. Track-10 readers НЕ нужен WHERE clause на events. Только team-membership queries (TEAM·N, JoinRequest list) partition per-workspace.

| Zone | Reader | Workspace-aware behaviour |
|---|---|---|
| **RESUME hero** (T2) | `GitDeltaReader` + last task identity | Device-wide reads. Active-workspace context shown as chip in hero. Cross-workspace checkouts — list all, active first. |
| **YOU·NOW badge** (T3) | `YouNowState` | Device-wide (badge shows my device state). |
| **NEEDS YOU** (T4) | `InboxFilter.actionable` | Reads device-wide events; renders all actionable items. Source attribution (workspace) — chip per row. (Не партиционируем events; UI tags only.) |
| **SINCE last active** (T5) | 14-kind activity feed | Device-wide events; rows tag chip per row showing workspace. |
| **TEAM·N broader pulse** (T6) | `TeamNRowComposer` | **Active workspace** members via `WorkspaceMembersReader` (partner's M019 substrate filter). Workspace switcher → re-render. |
| **YOU'RE ON** (T7) | `CurrentTaskSession` | Device-wide; workspace chip context. |
| **RECAP/EOD standup** (T8) | `StandupComposer` | Device-wide event feed + per-workspace blockers (D3 substrate). Standup shows my device standup + active workspace's open blockers. |
| **Analytics tab** (T1 hide) | hidden | Same. |

**Source of active workspace**: `ActiveWorkspaceStore.activeWorkspaceID` (partner's `LeafCore/Workspace/`). Default first workspace post-onboarding. Switcher persists.

---

## 7 — Migration sequence post-integration

| M-num | Owner | File | Purpose |
|---|---|---|---|
| M001..M009 | shared baseline | various | core schema (events, sessions, integrations, share_apps, share_event_types, watched_folders, etc) |
| M010 | Phase 5.5.A (наш) | `M010_PendingInvites.swift` | pending_invites table. **Schema preserved** partner'ом (migration safety) хотя UI код мёртв |
| M011..M014 | Track-1 D1/D2/D3 | various | EventKindIndex / EventsFTS / EventLinks / DetectionTables |
| M015..M018 | Track-3/-4 era | various | ProviderSnapshots / NormalizeGitHubEventKinds / NormalizeSlackEventKinds / IntensityAggregates |
| M019 | partner (Track-5/S2) | `M019_Workspaces.swift` | RENAME `org → workspaces` + add `workspace_id` FK columns в `team_members`, `team_keys`, `rotation_outbox`, `pending_invites`. **Events НЕ partitioned**. Per-workspace key sub-folders |
| M020 | partner (Track-5/S4) | `M020_MessagesMirror.swift` | Direct messages local mirror |
| M021 | partner (Track-5/S4) | `M021_APNsTokenLocal.swift` | APNs token local storage |
| M022 | partner (Track-5/S5) | `M022_ShareRules.swift` | Sharing rules substrate |
| M023 | partner (Track-5/S5/S7) | `M023_TeamEventsMirror.swift` | Team events local mirror (Realtime decryption) |
| M024 | partner (Track-5/S5/S7) | `M024_TeamEventBroadcastOffsets.swift` | Broadcast offsets per workspace |
| M025 | partner (Track-5/S8) | `M025_WorkspaceSoftDelete.swift` | Soft-delete + retention |
| M026 | partner (Track-5/S8) | `M026_S8Substrate.swift` | notification_prefs + pending_mark_done + waitlist + Auth Hook tier claim (combined) |
| M027 | partner (Invite Redesign) | `M027_InviteSystemRedesign.swift` | invite_tokens + join_requests |
| **M028** | мы (Track-6 P1 renumbered) | (renamed from M024) | `idx_events_ai_subagent` partial expression index |
| **M029** | мы (Track-6 P3 renumbered) | (renamed from M026) | domain allow-list для browsers |
| ~~M030~~ | (Track-6 P4 gcal_sync_tracker — deferred) | — | post-integration carry-over |

---

## 8 — Test baseline gate per phase

Числа — **estimates** (точные количества зависят от partner's HEAD на момент Phase I sync; обновятся в реальных phase logs).

| Phase | Pre-cherry-pick tests (estimate) | Post-phase target (estimate) | Privacy walkback |
|---|---|---|---|
| I — baseline | ~2155 SPM (partner's S8 line) + 14+ pgTAP files | same baseline; 5/5 schemes green | clean |
| II — Track-6 substrate | 2155 | +Track-6 sentinel-injection tests; ~2300+ SPM (est.) | grep 12 forbidden patterns → 0 hits |
| III — Track-8 P1 + Track-9 | 2300+ (est.) | +Track-9 substrate tests; ~2450+ SPM (est.) | aggregate-only / polish-only EXEMPT |
| IV.A — Track-10 UI | 2450+ (est.) | +Track-10 UI tests; ~2520+ SPM (est.) | T2/T5/T7 sentinel-injection preserved |
| IV.B — Workspace rewire | 2520+ (est.) | refactor tests `OrgReader` mocks → `WorkspaceReader`; ~2550+ SPM (est.) | clean — no new event_kinds |

Каждая phase = independent acceptance gate. No phase ships if test count regresses, build fails, или grep finds forbidden pattern.

---

## 9 — Risk register

| ID | Risk | Likelihood | Mitigation |
|---|---|---|---|
| R1 | **LeafCorePrivate moat coordination** — partner's `LeafCorePrivate/Prod/Collectors/` (ProdSlackChannelsProvider, ProdLinearTeamsProvider, fetchAccessibleUsers) не в git, нам нужны через приватный канал | High | Phase I list of missing files + transfer protocol с partner. До transfer — protocol stubs + mock providers в integration |
| R2 | **partner's Track-1..-4 versions могут drift от наших** (он merge'ил feature branches directly, у нас были follow-up fixes в main) | Medium | Phase I diff audit для Track-1 D2/D3, Track-2 D1-D4, Track-3 D1-D4, Track-4 S1-S4. Fix-bundle commit за расхождения |
| R3 | ~~`workspace_id` column в events?~~ **RESOLVED** (CTO C-2): M019 НЕ partitionирует events; только team_members/team_keys/rotation_outbox/pending_invites имеют workspace_id FK. Track-10 readers device-wide. | — | Reconciled in Section 6 |
| R4 | **`project.pbxproj` текстовый merge несостоятелен** | High | Каждую phase — после cherry-pick re-add files manually через Xcode. Verify сборка перед commit |
| R5 | **partner's continued bug-fixes на invite-redesign конфликтуют с integration** | High | Sync per phase boundary (см. Section 3). Если sync brings breaking change — separate fix-bundle commit как Stage 0 phase |
| R6 | ~~Workspace switcher UI partner уже сделал или нет?~~ **RESOLVED** (CTO C-3): `LeafWorkspaceSwitcher` уже в его Sidebar bottom (Track 5 / S7 G.12). Phase IV consume's, не add'ит. | — | Section 4 IV.B updated |
| R7 | **Track-6 P1 hook bridge bundle-embedding** — Sparkle ship prep | Medium | Acceptance gate Track-6 P1 уже включает bundle prep — preserve в Phase II |
| R8 | **`TeamNRowComposer` requires team members reader; multi-workspace makes filter complex** | Low | Use `WorkspaceMembersReader` (partner-branch M019 substrate). `composer` принимает workspaceID параметром |
| R9 | **Tests dependency injection — наши tests могут полагаться на `OrgReader` mock** | Medium | Phase III/IV — refactor tests на `WorkspaceReader` mock |
| R10 | **`EncryptedRow` + Realtime — Track-10 Inbox/TEAM·N может потреблять events напрямую vs encrypted feed** | Medium | Phase IV — Track-10 reads `events` table directly (substrate), не зависит от Realtime decryption path. Verify нет cross-talk |
| R11 | **`docs/superpowers/specs/` collision** — мы оба пишем specs в одну директорию | Low | partner's specs prefix'нуты `*invite-redesign*`, наши `*track-10-*`. Конкретный spec файл этой integration: `2026-05-24-track-10-x-workspace-integration-design.md` — unique slug |
| R12 | **`.claude/shared/*.md` divergence** — три файла (architecture / conventions / current-state) расходятся; оба не знают чужого track | High | После Phase IV — full rewrite `current-state.md`. Architecture/conventions — merge с pretext "источник правды partner-branch версия для team-layer, мы добавляем Track-10 zones description" |
| R13 | **partner's revert'нутый Supabase Edge Function refactor** — он может вернуться к нему | Medium | Sync per phase ловит. Если он re-applies — sync commit ловит, наш Track-10 не зависит от Edge Function bodies |

---

## 10 — Rollback plan

- Каждая phase — atomic commit (squash после passing acceptance).
- После failed phase acceptance: `git reset --hard <pre-phase-commit>`. Mы НИКОГДА не разрушаем чужую работу — integration branch только наша.
- Integration branch ПОКА не push'нута в `dev`/`main`. Force-push в `feature/integration-...` ok если нужно.
- partner's `feature/invite-redesign` НИКОГДА не трогаем destructively.
- Final acceptance gate (Phase IV done + manual two-Mac smoke) → push в `dev`. Любой rollback после dev push = revert PR на dev, не force-push.

---

## 11 — Out-of-scope / carry-overs

- **Track-6 P4 GoogleCalendar Deep** — defer под partner-branch Supabase OAuth flow (его tier-gate уже разрешает Google identity). Собственный spec post-integration.
- **Phase 5.4 v2 на Supabase Realtime** — наш own future track (broadcast presence через Supabase вместо leaf-relay WS). НЕ в этом integration.
- **`leaf-relay` Cloudflare Worker repo deprecation** — README + archive note, post-integration housekeeping.
- **Track-7 / Track-8 UI archive branches** — `feature/track-7-integration`, `feature/phase-8-*` не удалять; preserve для исторического reference.
- **`.claude/shared/current-state.md` final reconciliation** — после Phase IV полный rewrite (отдельным `docs(shared)` commit'ом).
- **Whitepaper sync** — `/sync-docs integration-T10-workspace` после merge в main: обновить `leaf-docs/docs/05-reference/changelog.md` + `architecture.md` (multi-workspace + Supabase + Track-10 zones).
- **`leaf-internal/architecture.yaml`** — update с финальным state (Track-5 + Track-6 substrate + Track-10 surfaces).

---

## 12 — Open questions

**RESOLVED inline by CTO pass 2026-05-24** (peek в partner's branch):
- ~~OQ-INT-1~~: events workspace_id partitioning — **NO** (Section 6).
- ~~OQ-INT-3~~: workspace switcher UI — **YES уже implement'нут** partner'ом (Section 4).
- ~~OQ-INT-5~~: M020-M025 — full inventory in Section 7.
- ~~OQ-INT-6~~: MCP tools — он содержит наш Track-1 D3 substrate (`leaf_query_activity`, `leaf_get_decision`, `leaf_current_work`) + `leaf_query_team`. Final post-integration = 16 tools (12 baseline + 3 structured + 1 team-query).

**RESOLVED via Phase I execution 2026-05-24**:
- ~~OQ-INT-2~~: LeafCorePrivate moat — **INVERSION-RESOLVED.** Original assumption wrong (situation bilateral, not unilateral). Phase I resolved через stash + LEAF_PROD flag toggle (Section 4 task 4 amended; Section 16 stash protocol). No MockProviders stubs created. Plan audit A-Audit-2.
- ~~OQ-INT-4~~: Track-1..-4 substrate drift — **NO Stage 0 fix-bundle required.** All observed drift = T10 forward evolution (Track-6/7/8/9/10 commits after Track-1..4 closure) absorbed via natural Phase II/III cherry-picks. No cases of partner-branch divergent content for same file. Plan audit A-Audit-1.
- ~~OQ-INT-7~~: Onboarding share-controls preset graft point — **DOCUMENTED.** Partner's `OnboardingStep` enum 6 states (`welcome/ax/fda/observers/team/done`); T10 added 2 cases (`aiTools`, `shareControls`) between `observers` и `team`. Phase IV.A: extract `applyShareControlsPreset()` pure function в `LeafCore/ShareControls/`; insert 2 new cases в partner's enum; cherry-pick `ShareControlsStepView` + `AIToolsStepView` adapting `OrgReader → WorkspaceReader`; idempotent guard. Plan audit A-Audit-3.

**All OQ items closed.** No Phase I open questions remaining at Phase II entry.

---

## 13 — Success criteria

После Phase IV merge integration → dev → main:

- ✅ Multi-workspace context работает (`LeafWorkspaceSwitcher` в sidebar + per-workspace zones для TEAM·N + standup blockers).
- ✅ Все partner's Track-5 / Invite-Redesign функционал preserved (G1-G22 pass).
- ✅ Все Track-10 zones операциональны и visually correct.
- ✅ Track-6 substrate landed (capture depth alpha; +Track-6 event_kinds в registry).
- ✅ Track-9 substrate enrichment landed (cross-provider pulse derivers).
- ✅ **16 MCP tools final inventory** (12 baseline low-level + 3 structured Track-1 D3 [`leaf_query_activity`, `leaf_get_decision`, `leaf_current_work`] + 1 team-query [`leaf_query_team`]).
- ✅ Test baseline ~2550+ SPM all pass (est.); 5/5 xcodebuild schemes green; GitHub Actions CI green on integration branch (if CI workflows applicable).
- ✅ Privacy walkback по 12 forbidden patterns clean.
- ✅ Whitepaper synced с финальным state (multi-workspace + Supabase + Track-10 zones).
- ✅ `leaf-internal/architecture.yaml` updated.
- ✅ `.claude/shared/current-state.md` reconciled (both workstreams unified).

---

## 14 — Plan placement

Per local memory `feedback_plan_storage_for_phases` — каждая phase'ная сессия пишет свой плана-файл в `.claude/plans/integration-T10-phase-<I|II|III|IVA|IVB>.md` перед началом implementation. Этот spec — design doc; per-phase plans — execution roadmaps.

---

## 15 — CTO pass log (2026-05-24)

| ID | Sev | Finding | Disposition |
|---|---|---|---|
| C-1 | CRIT | M020-M025 inventory unknown | RESOLVED inline — Section 7 |
| C-2 | CRIT | OQ-INT-1 events workspace_id | RESOLVED inline — events NOT partitioned (Section 6, R3) |
| C-3 | CRIT | Workspace switcher status | RESOLVED inline — already implement'нут partner (Section 4 IV.B, R6) |
| C-4 | CRIT | M010 PendingInvites table | RESOLVED — preserved in schema; UI dropped only (Section 4 IV.B, Section 7) |
| C-5 | CRIT | Track-1 D3 substrate inheritance | RESOLVED — confirmed shared; 16 MCP tools total (Section 13) |
| H-1 | HIGH | Phase IV split criterion vague | RESOLVED — IV.A/IV.B committed from start (Section 4) |
| H-2 | HIGH | Onboarding share-controls preset injection | RESOLVED — new OQ-INT-7 (Section 12) |
| H-3 | HIGH | MCP tool count в success criteria | RESOLVED — 16 tools stated (Section 13) |
| H-4 | HIGH | Test baseline numbers — estimate qualifier | RESOLVED — "estimate" added (Section 8) |
| H-5 | HIGH | Sync collision M028/M029 mid-track | RESOLVED — early-commit names в Phase I task 6 (Section 4) |
| H-6 | HIGH | No CI mention | RESOLVED — added (Section 4 task 5, Section 13) |
| M-1..M-4 | MED | wording / contradictions | RESOLVED inline |
| L-1..L-3 | LOW | Reviewed-By field / glossary / rollback | L-2 added (frontmatter); L-1 OK; L-3 skipped (whitepaper has terminology) |

---

## 16 — Stash protocol (Phase I baseline → Phase IV restore)

**Added 2026-05-24** during Phase I execution. Section 4 task 4 originally assumed unilateral missing-files state; reality is bilateral (each developer has own gitignored `LeafCorePrivate/Prod/`). Protocol:

### Phase I stash-aside (executed)

При first checkout integration branch off partner's HEAD:

```bash
# 1. Stash own LeafCorePrivate/Prod (73 .swift files on integration-T10 baseline).
STASH=~/Desktop/Leaf/leaf-integration-prod-stash
mkdir -p "$STASH"
mv Packages/LeafCore/Sources/LeafCorePrivate/Prod \
   "$STASH/Prod-T10-baseline-$(date +%Y%m%d-%H%M%S)"

# 2. Stash own LeafCorePrivateTests (74 .swift; preserve Placeholder.swift).
STASH_T="$STASH/LeafCorePrivateTests-T10-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$STASH_T"
for f in Packages/LeafCore/Tests/LeafCorePrivateTests/*.swift; do
  [ "$(basename $f)" = "Placeholder.swift" ] || mv "$f" "$STASH_T/"
done

# 3. Toggle LEAF_PROD off в gitignored Config/Local.xcconfig.
# (manual edit: LEAF_FLAGS = LEAF_PROD → LEAF_FLAGS = )

# 4. Verify baseline green.
just build-all   # → 5/5 BUILD SUCCEEDED
just test-core   # → 2315 XCTest + 52 SwiftTesting, 0 failures
```

### Phase II/III/IV.A interim — no action

Track-6 substrate cherry-picks (Phase II) progressively restore the LeafCore symbols that наш Prod/ stash references. После Phase II Track-6 P3 + P5 land, our stashed Prod files become semantically valid again (но мы их пока не возвращаем — production build pathway requires partner's Prod files too).

### Phase IV.B / pre-merge restore protocol

После Phase IV.B done, **before** merge integration → dev:

```bash
# 1. Restore наш Prod stash (Track-6 substrate now landed via Phase II cherry-picks → compiles).
mv "$STASH/Prod-T10-baseline-<ts>" Packages/LeafCore/Sources/LeafCorePrivate/Prod

# 2. Restore LeafCorePrivateTests stash similarly.
mv "$STASH/LeafCorePrivateTests-T10-<ts>"/*.swift \
   Packages/LeafCore/Tests/LeafCorePrivateTests/

# 3. Production ship path: partner transfers real prod files via private channel
#    BEFORE flipping LEAF_FLAGS = LEAF_PROD. Partner's symbols (ProdConfigs etc.)
#    still missing from git per R1.

# 4. Verify partial green (LEAF_PROD off):
just build-all   # → 5/5 green с inline non-prod stubs

# 5. After partner transfer, flip LEAF_FLAGS = LEAF_PROD and re-verify.
just build-all   # → 5/5 green с real prod implementations
```

### Risk: stash directory deletion

If `~/Desktop/Leaf/leaf-integration-prod-stash/` accidentally deleted before restore — наш Prod/ moat lost (gitignored, no git history). Recovery: re-cherry-pick from `feature/track-10-operational-home` branch (Prod/ may also be gitignored там; check Time Machine).

**Mitigation**: keep `feature/track-10-operational-home` branch alive локально + на origin через всю integration lifecycle (R12 mitigation already in Section 9). Periodic Time Machine snapshots of stash dir recommended.
