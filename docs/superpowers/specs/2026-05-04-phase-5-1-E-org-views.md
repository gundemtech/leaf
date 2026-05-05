# Phase 5.1.E — `OrganizationView` / `TeamView` + integration test + landing

**Status:** Active (2026-05-05). Fifth and final sub-project of Phase 5.1.x stack.
**Owner:** Dmitrii.
**Stack:** branches off `feature/phase-5-1-D` (which holds 5.1.A + 5.1.B + 5.1.C + 5.1.D commits).

---

## 1. Context

Phase 5.1.E — пятая и закрывающая sub-phase substrate-stack'а Phase 5.1. Контракт уровня всей фазы — `2026-05-04-phase-5-architecture-contract.md`, §9 (boundary matrix).

Текущее состояние:

- **5.1.A** landed schema substrate (M006 `org` / M007 `team_members` / M008 `team_keys`) + `TeamMemberRole` enum.
- **5.1.B** landed value types (`Org` / `TeamMember` / `TeamKey`) + 6 GRDB helpers inline в `Database.swift`.
- **5.1.C** landed `EnvelopeCodec` real impl (AES-GCM-256) + `EnvelopeHeader.peek` + `ProdEnvelopeCodec` (gitignored).
- **5.1.D** landed `OrgService.createPersonalOrg(displayName:)` + `currentOrg()` + `TeamKeystore` writers (X25519 priv + per-rotation teamKey файлы, 0o600).
- **`OrganizationView` / `TeamView`** — placeholders `EmptyStateView(phase: ...)`; никакого UI-пути создать org нет.
- **`OrgService` нигде не инстанцируется** в `LeafApp.init` — substrate стоит сухой.
- Test targets: `LeafCoreTests` baseline 691 после 5.1.C; +14 тестов от 5.1.D (`TeamKeystoreTests` 8 + `OrgServiceTests` 12 — фактически landed) → ≈705.

**Зачем сейчас:** Phase 5.1.D дала domain service + keystore writers, но никакого пути изнутри приложения создать org нет — substrate материализуется только из unit-тестов. 5.1.E замыкает substrate в работающий self-flow: solo юзер открывает Organization, видит CTA, вводит display name, жмёт Create — три row'а в DB + два keystore-файла материализуются, обе вкладки показывают живой контент. После 5.1.E: один реальный self-admin member, один initial teamKey, X25519 keypair — substrate под Phase 5.2 invite UX полностью готов.

**Источники правды (priority при противоречии):**

1. `2026-05-04-phase-5-architecture-contract.md` — §4 (identity model: single-org-per-device), §9 (boundary matrix).
2. `leaf-docs/docs/03-architecture/presence-relay.md` — public flow shape.
3. Существующий `Leaf/Models/InsightsReader.swift` + `Leaf/Integrations/*/OAuthService.swift` — code-style template для `@Observable` reader + lazy DB open.

---

## 2. Scope

### Входит

| Артефакт | Файл | Заметка |
|---|---|---|
| `OrgReader` Observable wrapper | `Leaf/Models/OrgReader.swift` (new) | `@MainActor @Observable final class`. State machine `.loading` / `.empty` / `.loaded(Org, [TeamMember])` / `.error(message)`. `refresh()` + `createPersonalOrg(displayName:)` синхронные (file/DB write < 50ms). Inject DB path / config / encryption / keystore root для тестабельности (не используется в 5.1.E прямо, но parameter-substrate под cleanup). |
| `OrganizationView` real content | `Leaf/Views/Window/Organization/OrganizationView.swift` (rewrite) | Switch state: `.loading` → ProgressView; `.empty` → headline + Create form; `.loaded(org, _)` → org-card с name + createdAt + single-org-per-device blurb; `.error` → message + Retry. |
| `TeamView` real content | `Leaf/Views/Window/Team/TeamView.swift` (rewrite) | Switch state: `.loading` → ProgressView; `.empty` → "No team yet" + jump-to-Organization button; `.loaded(_, members)` → list of member cards (initials avatar + display name + role badge + monospaced pubkey hex prefix `aabb…ccdd`). |
| LeafApp wiring | `Leaf/LeafApp.swift` (edit) | `@State var orgReader = OrgReader()` + `.environment(orgReader)` для main `Window` scene. `MenuBarContent` НЕ получает (out-of-scope; presence in menubar — 5.4). |
| Persistence E2E integration test | `Packages/LeafCore/Tests/LeafCoreTests/OrgPersistenceIntegrationTests.swift` (new) | 3 теста: reopen-DB-and-keystore-survive, reopen-idempotency-throws, file-bytes-match-injected. Mirror harness `OrgServiceTests`. |
| Landing commit | `.claude/shared/current-state.md` (edit) | Mirror 5.1.A/B/C/D pattern: дата + "Phase 5.1.E landed" + 1 абзац концепта + commits/test count. |

### НЕ входит (явно отложено)

- **Onboarding screen 6** ("Team — join via invite OR create personal org" welcome flow на first launch) — **5.5** per контракт §9. 5.1.E surface'ит CTA только из Organization tab.
- **Invite UX, member add** — **5.2** (X25519 ECDH + HKDF + relay endpoints).
- **Remove member, key rotation** — **5.3**.
- **Presence broadcast, team grid, presence_outgoing/history migrations** — **5.4**.
- **Settings/billing tier UI** — out-of-MVP.
- **Whitepaper sync** — 5.1.E impl-уровень substrate UI; existing whitepaper presence-relay.md уже описывает intended flow абстрактно. Single changelog entry при alpha-ship'е, не правки контента.
- **`MenuBarContent` org status** — 5.4 (presence indicator).

---

## 3. Public API design

### `OrgReader` (Leaf/Models)

```swift
@MainActor
@Observable
final class OrgReader {
    enum State {
        case loading
        case empty
        case loaded(Org, [TeamMember])
        case error(message: String)
    }

    private(set) var state: State = .loading

    init(databaseURL: URL = DatabasePath.defaultURL(),
         databaseConfig: DatabaseConfig = OrgReader.defaultConfig(),
         databaseEncryption: EncryptionOptions? = OrgReader.defaultEncryption(),
         keystoreRoot: URL = TeamKeystore.defaultRoot())

    /// Idempotent. Reads org + members from DB into state. Called on view appear.
    func refresh()

    /// Synchronous DB+keystore write. State → .loaded(...) on success.
    /// LeafError.orgAlreadyExists / .invalidPayload → state → .error(message).
    func createPersonalOrg(displayName: String)
}
```

Concurrency: `@MainActor` mirror `InsightsReader` — observation publish + UI render в одной isolation. File/DB writes <50ms; sync-on-main acceptable (как в `LinearOAuthService.disconnect`). Если bottleneck surfaces в bench'и 5.4 — оптимизировать `Task.detached` детачем (no preemptive optimization).

`databaseURL` default = `DatabasePath.defaultURL()` (canonical через все service'ы); `databaseConfig` / `databaseEncryption` mirror `InsightsReader.defaultConfig()` (LEAF_PROD → ProdConfigs, иначе weakDefaults / nil).

### Error mapping (private LocalizedError helper inside `OrgReader.swift`)

```swift
private extension LeafError {
    var userFacingMessage: String {
        switch self {
        case .orgAlreadyExists:
            return "An organization already exists on this device."
        case .invalidPayload:
            return "Workspace name can’t be empty."
        case .keyFileUnavailable, .keyFileCorrupted:
            return "Couldn’t access local keystore. Try restarting the app."
        case .keychainUnavailable:
            return "Couldn’t generate secure random data. Try again."
        default:
            return "Something went wrong. Please try again."
        }
    }
}
```

Generic `Error` (not `LeafError`) → "Couldn't create organization. See Console for details."

---

## 4. UI design

### `OrganizationView`

```
┌─ ScrollView ────────────────────────────────────────┐
│  ORGANIZATION (label)                                │
│  Create your personal org. (headline)                │
│                                                      │
│  blurb: "Solo for now — invite teammates later."     │
│                                                      │
│  ┌─ GlassCard ────────────────────────────────────┐ │
│  │  Workspace name                                 │ │
│  │  ┌───────────────────────────────────┐          │ │
│  │  │ My Workspace                      │          │ │
│  │  └───────────────────────────────────┘          │ │
│  │                                                 │ │
│  │  [ Create personal org ]  ← disabled if empty   │ │
│  └─────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────┘
```

Loaded state — same layout, GlassCard shows org name + "Created \<date\>" + blurb "Single-org-per-device — to switch, wipe local data first."

### `TeamView`

Empty: similar to current `EmptyStateView` style + "Go to Organization" button.

Loaded:
```
┌─ ScrollView ────────────────────────────────────────┐
│  TEAM · 1 MEMBER                                     │
│  Your team                                           │
│                                                      │
│  ┌─ GlassCard ─ row ─────────────────────────────┐  │
│  │  ⓐ  Alice               [ADMIN]               │  │
│  │      aabbccdd…eeffaabb (monospaced)            │  │
│  └────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────┘
```

`ⓐ` = circle с initials (first 2 letters uppercased). Pubkey prefix = 8 + ellipsis + 8 chars от 64-char hex.

---

## 5. Test plan

### `OrgPersistenceIntegrationTests.swift` (3 теста)

Harness mirror `OrgServiceTests`: tempDir + `.deterministicTest` encryption + tempDir keystore.

1. **`testCreate_DBAndKeystoreSurviveReopen`** — `OrgService.createPersonalOrg("Personal")` → `db = nil` → re-open `Database.openForWrite(at: dbURL, ...)` → assert `readOrg()` matches saved Org by id/name/createdAt/createdByMemberID; `readTeamMembers(orgID:)` returns 1 admin row; `readActiveTeamKey()` matches saved teamKey. Plus assert keystore files: `<root>/x25519.priv` exists 32B; `<root>/team-keys/<teamKeyID>.key` exists 32B.
2. **`testCreate_SecondAttempt_AfterReopen_ThrowsOrgAlreadyExists`** — create → `db = nil` → re-open → second `OrgService` instance с same DB+keystore → `createPersonalOrg("Other")` throws `LeafError.orgAlreadyExists`. Подтверждает idempotency через DB persist (не in-memory cache).
3. **`testCreate_KeystoreTeamKeyFileBytesMatchInjected`** — inject sentinel `randomBytes` returning fixed 32B pattern → after create, read raw `<root>/team-keys/<id>.key` bytes from disk → assert equal sentinel. Закрывает gap "DB row id-references file, файл реально содержит то что обещано".

> **Не дублируем** OrgServiceTests test 11 (X25519 priv→pub derivation match) — там single-instance flow покрывает; reopen не меняет байты файла на диске.

Target test count: 705 → 708 (+3).

### Manual smoke (post-Stage 5)

1. `xcodebuild -scheme Leaf -configuration Debug build` зелёный.
2. Run Debug app (Xcode Run).
3. Open main Window, switch to Organization tab.
4. **Empty state visible:** Create CTA + form.
5. Submit empty name → button disabled.
6. Submit "My Workspace" → state mгновенно switches на loaded → headline = "My Workspace", "Created \<today\>".
7. Switch to Team tab → 1 row "self-admin" с display name "My Workspace", role "Admin", pubkey hex prefix.
8. Quit + relaunch Debug app → both tabs immediately show loaded state.
9. SQLCipher REPL on `~/Library/Application Support/Leaf/events.sqlite` (Debug encryption=plaintext): `SELECT * FROM org;` `SELECT id,role,display_name FROM team_members;` `SELECT id FROM team_keys;` — каждая ровно 1 row.
10. Verify keystore files: `ls -la ~/Library/Application\ Support/Leaf/keystore/x25519.priv` и `~/Library/Application\ Support/Leaf/keystore/team-keys/*.key` — 0o600, 32B каждый.

### Build verification

- `cd Packages/LeafCore && swift test` — все targets зелёные, +3 теста.
- `xcodebuild -scheme Leaf build` + `LeafAgent` + `LeafMCP` + `LeafCore` + `LeafCorePrivate` — все 5 BUILD SUCCEEDED.
- `git status` clean.
- `/pre-push-leaf` clean (UI bullets про AES-GCM/X25519 уже в whitepaper, см. EmptyStateView line 36).

---

## 6. Commit decomposition

Sequential, atomic. Каждый commit оставляет tree green.

| # | Commit | Файлы |
|---|---|---|
| 0 | `docs(specs): Phase 5.1.E — OrganizationView/TeamView spec + plan` | `docs/superpowers/specs/2026-05-04-phase-5-1-E-org-views.md` (this) + `.claude/plans/phase-5-1-E.md` |
| 1 | `test(core): Phase 5.1.E — DB+keystore reopen integration test` | `Tests/LeafCoreTests/OrgPersistenceIntegrationTests.swift` |
| 2 | `feat(app): Phase 5.1.E — OrgReader Observable state machine` | `Leaf/Models/OrgReader.swift` |
| 3 | `feat(app): Phase 5.1.E — OrganizationView real content + Create CTA` | `Leaf/Views/Window/Organization/OrganizationView.swift` + `Leaf/LeafApp.swift` |
| 4 | `feat(app): Phase 5.1.E — TeamView members list` | `Leaf/Views/Window/Team/TeamView.swift` |
| 5 | `docs(shared): Phase 5.1.E landed — current-state update` | `.claude/shared/current-state.md` |

Push: `git push -u origin feature/phase-5-1-E` после commit 5. Code review (`superpowers:code-reviewer`) на полном branch'е, потом merge в main отдельным шагом.

---

## 7. Acceptance criteria

- ☐ `OrgReader` инстанцируется без eager DB-open; первый `refresh()` тригерит open lazily.
- ☐ State machine maps `LeafError.orgAlreadyExists` → "An organization already exists on this device."
- ☐ `OrganizationView` показывает Create CTA при `.empty`; submit с непустым name создаёт org за один tap.
- ☐ `TeamView` показывает self-admin row после create; pubkey hex prefix отрисован monospaced.
- ☐ Quit+relaunch persists state (после next launch обе вкладки сразу loaded).
- ☐ 3 new integration tests зелёные; total `swift test` ≈ 708.
- ☐ Все 5 xcodebuild schemes BUILD SUCCEEDED.
- ☐ Manual smoke (§5) проходит на Debug build.
- ☐ Composition root в `Agent.swift` НЕ изменён.
- ☐ `/pre-push-leaf` clean.
- ☐ `.claude/shared/current-state.md` обновлён landing entry'ом.

---

## 8. Open considerations

- **DB pool count** — каждый Reader (Insights + Org) держит свой pool на тот же файл. Текущая практика; если 5.4 bench'и покажут contention — выделим shared `DatabaseHolder` cleanup-фазой.
- **Form local state** — `@State private var name = ""` внутри `OrganizationView` (не в reader). Disposable input — нет смысла переживать в shared state.
- **`refresh()` debounce** — два `.onAppear` (RootView + OrganizationView) могут дёрнуть refresh дважды. SQLite read дешёвая; не оптимизируем preemptively. Если flicker наблюдается — guard `if case .loading = state` в Stage 5.
- **TeamView "Go to Organization"** — нужен `@Environment(WindowState.self)` для `windowState.section = .organization`. Pattern уже использует Sidebar.

---

*End of spec. Tactical plan follows in `.claude/plans/phase-5-1-E.md`.*
