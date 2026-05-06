# Phase 5.1.A — Migrations (org / team_members / team_keys)

**Status:** Active (2026-05-04). First sub-project of Phase 5.
**Owner:** Dmitrii.
**Promotes:** `docs/superpowers/specs/2026-05-04-phase-5-architecture-contract.md` from Draft → Active (per contract §1).

---

## 1. Context

Phase 5.1.A — первая sub-phase Phase 5 ("team presence relay"). Контракт уровня всей фазы зафиксирован в `2026-05-04-phase-5-architecture-contract.md` (§9 boundary matrix фиксирует deliverable):

> M006 `org`, M007 `team_members`, M008 `team_keys` миграции + Schema namespace + 1 enum (`TeamMemberRole`).

Никаких сервисов / writers / value-types / реальных rows в этой фазе. **Только schema** — substrate под:

- 5.1.B → GRDB-style helpers + value types (`Org` / `TeamMember` / `TeamKey`).
- 5.1.C → `EnvelopeCodec` real impl (replaces `UnimplementedEnvelopeCodec`).
- 5.1.D → `OrgService.createPersonalOrg` + keystore writers — первые rows в трёх таблицах.
- 5.1.E → UI (`OrganizationView` / `TeamView` real content), integration test, landing commit.

**Зачем сейчас:** все три таблицы — append-only поверх 5 уже applied (M001..M005). Никаких behavioural изменений — пустые таблицы создаются; existing alpha.9 пользователи получат их при первом open после ship'а 5.1.E. Substrate должен быть готов до 5.1.B/C/D.

**Источники правды (priority при противоречии):**

1. `leaf-docs/docs/03-architecture/storage.md` — table list (line 118-120).
2. `2026-05-04-phase-5-architecture-contract.md` — §4 Identity, §7 Key lifecycle, §9 boundary, §10 Failure modes.
3. M001..M005 — code-style template.

---

## 2. Scope

### Входит

| Артефакт | Файл | Заметка |
|---|---|---|
| `TeamMemberRole` enum | `Packages/LeafCore/Sources/LeafCore/Team/TeamMemberRole.swift` (новый домен-фолдер `Team/`) | cases `admin` + `member`; `String, Codable, Sendable, CaseIterable` |
| Schema namespaces | `Packages/LeafCore/Sources/LeafCore/DB/Schema.swift` (extend) | три новых nested enum'а — `Schema.Org`, `Schema.TeamMembers`, `Schema.TeamKeys` |
| M006 migration | `Packages/LeafCore/Sources/LeafCore/DB/Migrations/M006_Org.swift` | `CREATE TABLE org` |
| M007 migration | `Packages/LeafCore/Sources/LeafCore/DB/Migrations/M007_TeamMembers.swift` | `CREATE TABLE team_members` + 1 partial index |
| M008 migration | `Packages/LeafCore/Sources/LeafCore/DB/Migrations/M008_TeamKeys.swift` | `CREATE TABLE team_keys` + 1 partial index |
| Database.swift register | `Packages/LeafCore/Sources/LeafCore/DB/Database.swift:38-44` | append 3 строки `migrator.registerMigration00X...()` |
| Tests | `Packages/LeafCore/Tests/LeafCoreTests/MigrationTests.swift` (extend) | 8 тестов |

### НЕ входит (явно отложено)

- GRDB record types / value structs (`Org`, `TeamMember`, `TeamKey`) — 5.1.B.
- Helpers `db.upsertOrg(...)` / `db.readTeamMembers(...)` — 5.1.B.
- Keystore writers / X25519 / AES-GCM — 5.1.C / 5.1.D.
- `OrgService.createPersonalOrg` — 5.1.D. Таблицы создаём пустыми.
- UI (`OrganizationView` / `TeamView` real content) — 5.1.E.
- Изменения `Database.swift` сверх 3-строчного append к migration register'у.

---

## 3. Schema design

### `Schema.Org` (one-row table)

| SQL column | Swift const | Type | Nullability | Notes |
|---|---|---|---|---|
| `id` | `Schema.Org.id` | TEXT | PK NOT NULL | UUID v4 raw string; single-org-per-device — lишь 1 row reachable |
| `name` | `Schema.Org.name` | TEXT | NOT NULL | display name; "Personal" preset для `createPersonalOrg` (5.1.D) |
| `created_at_ms` | `Schema.Org.createdAtMs` | INTEGER | NOT NULL | epoch ms |
| `created_by_member_id` | `Schema.Org.createdByMemberID` | TEXT | NOT NULL | UUID v4 матчит `team_members.id` self-row; logical FK без SQL constraint (см. §4) |

Без default'ов. Без CHECK. Без index'ов (1 row).

### `Schema.TeamMembers`

| SQL column | Swift const | Type | Nullability | Notes |
|---|---|---|---|---|
| `id` | `Schema.TeamMembers.id` | TEXT | PK NOT NULL | UUID v4, member identity (contract §4) |
| `org_id` | `Schema.TeamMembers.orgID` | TEXT | NOT NULL | logical FK на `org.id` |
| `role` | `Schema.TeamMembers.role` | TEXT | NOT NULL | `TeamMemberRole.rawValue` (`"admin"` / `"member"`) |
| `pubkey_hex` | `Schema.TeamMembers.pubkeyHex` | TEXT | NOT NULL | X25519 public key, 64-hex-char (32 bytes); contract §7 |
| `display_name` | `Schema.TeamMembers.displayName` | TEXT | NOT NULL | человекочитаемое имя в UI; default `""` ради идемпотентности при system-username fallback |
| `added_at_ms` | `Schema.TeamMembers.addedAtMs` | INTEGER | NOT NULL | epoch ms |
| `removed_at_ms` | `Schema.TeamMembers.removedAtMs` | INTEGER | nullable | NULL = active member; устанавливается в Phase 5.3 на removal |

**Index:** `team_members_org_active` partial — `CREATE INDEX team_members_org_active ON team_members(org_id) WHERE removed_at_ms IS NULL`. Под frequent query "active members этой org" в Team UI.

Без CHECK на role enum (validated в Swift через `TeamMemberRole(rawValue:)`).

### `Schema.TeamKeys`

| SQL column | Swift const | Type | Nullability | Notes |
|---|---|---|---|---|
| `id` | `Schema.TeamKeys.id` | TEXT | PK NOT NULL | rotation UUID v4; embedded as `keyID` в envelope (contract §6 — 16 bytes) |
| `generated_at_ms` | `Schema.TeamKeys.generatedAtMs` | INTEGER | NOT NULL | epoch ms |
| `deprecated_at_ms` | `Schema.TeamKeys.deprecatedAtMs` | INTEGER | nullable | NULL = current rotation; set в Phase 5.3 |
| `generated_by_member_id` | `Schema.TeamKeys.generatedByMemberID` | TEXT | NOT NULL | audit who created rotation; logical FK на `team_members.id` |

**Index:** `team_keys_active` partial — `CREATE INDEX team_keys_active ON team_keys(deprecated_at_ms) WHERE deprecated_at_ms IS NULL`. Под query "current key" дешёво.

**Envelope ↔ DB mapping:** `keyID` в envelope — 16 raw bytes (UUID). DB column хранит string-form UUID для consistency с `org.id` / `team_members.id`. Encoding 16B↔hex-UUID — забота 5.1.C `EnvelopeCodec`, не migration scope.

---

## 4. FK strategy (отступление от обычной SQL дисциплины)

**Решение:** не объявлять SQL `FOREIGN KEY` constraint'ы.

**Почему:**

1. SQLite enforces FK только если `PRAGMA foreign_keys = ON` per-connection — текущий `Database.applyEncryption` это не выставляет. Декларировать FK без enforcement = false sense of safety.
2. **Insertion order paradox** в 5.1.D `createPersonalOrg`: первый row team_members ссылается на org.id, а org.created_by_member_id ссылается на team_members.id. Без deferred FK (SQLite не поддерживает эффективно для DDL FK) one-of-them всегда нарушит constraint на момент INSERT.
3. Все ссылки — под нашим контролем (не user-input), один writer-process (Agent), validated в Swift на уровне value types (5.1.B).
4. Documentation comment "logical FK to X.Y" в Schema.swift — code reviewer'ам видно.

**Reversibility:** если позже понадобится — отдельная migration с table-rebuild через `sqlite_master` rewrite (SQLite не поддерживает `ALTER TABLE ADD CONSTRAINT FK`).

---

## 5. TeamMemberRole

```swift
// Packages/LeafCore/Sources/LeafCore/Team/TeamMemberRole.swift
import Foundation

/// Phase 5.1.A — роль member в org. Stored as TEXT в team_members.role.
/// Contract §4: admin несёт org/billing/invite permissions, БЕЗ
/// privileged read access (Share Controls invariant — admin симметричен).
public enum TeamMemberRole: String, Codable, Sendable, CaseIterable {
    case admin
    case member
}
```

Mirrors `IntegrationProvider` (`Schema.swift:94`) и `SignalType` (`Signals/SignalType.swift`).

Folder `Team/` — новый домен по аналогии с `Presence/` / `Share/` / `Integrations/`. Будет растить value types в 5.1.B.

---

## 6. Migration files (template per M005)

Каждая migration = single `extension DatabaseMigrator` + `mutating func registerMigration00XName()` + `registerMigration("00X_name")` блок. `ifNotExists: true` mirroring M005.

```swift
// M006_Org.swift
public extension DatabaseMigrator {
    mutating func registerMigration006Org() {
        registerMigration("006_org") { db in
            try db.create(table: Schema.Org.tableName, ifNotExists: true) { t in
                t.primaryKey(Schema.Org.id, .text)
                t.column(Schema.Org.name, .text).notNull()
                t.column(Schema.Org.createdAtMs, .integer).notNull()
                t.column(Schema.Org.createdByMemberID, .text).notNull()
            }
        }
    }
}
```

M007 / M008 аналогично + partial index через GRDB 7 `condition:` parameter:

```swift
try db.create(
    index: Schema.TeamMembers.indexOrgActive,
    on: Schema.TeamMembers.tableName,
    columns: [Schema.TeamMembers.orgID],
    condition: Column(Schema.TeamMembers.removedAtMs) == nil
)
```

---

## 7. Database.swift register

`Database.swift:38-44`:

```swift
var migrator = DatabaseMigrator()
migrator.registerMigration001Events()
migrator.registerMigration002CollectorOffsets()
migrator.registerMigration003WatchedFolders()
migrator.registerMigration004Integrations()
migrator.registerMigration005PresenceState()
migrator.registerMigration006Org()              // <-- new
migrator.registerMigration007TeamMembers()      // <-- new
migrator.registerMigration008TeamKeys()         // <-- new
try migrator.migrate(pool)
```

GRDB applies в registration order; idempotent по identifier — повторный open не пересоздаёт.

---

## 8. Tests (`MigrationTests.swift` extend)

Mirroring `testMigration005CreatesPresenceStateTable` shape (`MigrationTests.swift:90-128`).

| # | Test | Что проверяет |
|---|---|---|
| 1 | `testMigration006CreatesOrgTable` | table exists + 4 columns по имени |
| 2 | `testMigration006OrgPrimaryKeyIsId` | `PRAGMA table_info(org)` → `id` имеет `pk=1`, `notnull=1` |
| 3 | `testMigration007CreatesTeamMembersTable` | table + 7 columns; `removed_at_ms` `notnull=0`, остальные `notnull=1` |
| 4 | `testMigration007CreatesActiveIndex` | `team_members_org_active` index присутствует в `sqlite_master` |
| 5 | `testMigration008CreatesTeamKeysTable` | table + 4 columns; `deprecated_at_ms` `notnull=0` |
| 6 | `testMigration008CreatesActiveIndex` | `team_keys_active` index присутствует |
| 7 | `testMigration006To008AreIdempotent` | open + reopen — не падает (mirror `testMigration001IsIdempotent`) |
| 8 | `testMigration006To008CoexistWithEarlier` | после полного open `sqlite_master` содержит все 8 tables (sanity) |

Test count baseline: 652 (Phase 4.10.B). Ожидаемо +8 → 660.

---

## 9. Branching / commits

- Branch: `feature/phase-5-1-A`.
- Commits (atomic per Stage 5 step):
  1. `feat(core): Phase 5.1.A — TeamMemberRole enum + Schema.Org/TeamMembers/TeamKeys`
  2. `feat(core): Phase 5.1.A — M006 org migration + tests`
  3. `feat(core): Phase 5.1.A — M007 team_members migration + tests`
  4. `feat(core): Phase 5.1.A — M008 team_keys migration + tests`
  5. `docs(shared): Phase 5.1.A landed — current-state update`
- **Pre-push:** `/pre-push-leaf`. Ожидаемо чисто — schema names уже public в whitepaper, никаких SQL bodies / pragma values / crypto bytes.

---

## 10. Whitepaper sync (после landing)

Triggered automatically per root `CLAUDE.md` "Whitepaper — source of truth":

- `leaf-docs/docs/03-architecture/storage.md`:
  - Table count update — было 16 (с `presence_state`), станет 19 (`+ org`, `+ team_members`, `+ team_keys`).
  - Admonition `!!! note "Изменение vX.Y — 2026-05-04 (Phase 5.1.A — team-crypto schema)"` — пометка "**rows нет**, только schema substrate".
- `leaf-docs/docs/05-reference/changelog.md` — entry `- **2026-05-04 HH:MM · Dmitrii** — Phase 5.1.A landed: M006/M007/M008 schema substrate под team relay (no behavioural change, пустые таблицы).`
- `presence-relay.md` НЕ трогаем — column-level details не уходят в public.

Implementation moat (FK strategy reasoning, partial-index choices, insertion-order paradox) **не уходит** в whitepaper — остаётся в этом spec'е + phase plan.

---

## 11. Verification

1. **Build:** `xcodebuild` для всех 5 schemes (Leaf / LeafAgent / LeafMCP / LeafCore / LeafCorePrivate). BUILD SUCCEEDED для всех.
2. **SPM tests:** `swift test --package-path Packages/LeafCore` → 660 tests pass (652 + 8 new).
3. **Manual REPL** (опционально):
   ```bash
   sqlcipher ~/Library/Application\ Support/Leaf/events.sqlite
   sqlcipher> PRAGMA key = "x'<hex>'";
   sqlcipher> .tables
   ```
   Должны видеть `org`, `team_members`, `team_keys` рядом с existing tables.
4. **Idempotency runtime:** Sparkle Beta channel ship → второй launch не падает с migration error.
5. **Pre-push:** `/pre-push-leaf` → expected clean.

---

## 12. Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | Existing alpha.9 пользователи получат миграции при первом launch ship'а 5.1.E. Если M006-M008 fail на edge case — App refuses to start. | Tests покрывают idempotency + table_exists. Контракт §10 fallback — rename DB to `.bak`. |
| R2 | `display_name` NOT NULL может оказаться tight constraint в 5.1.D. | 5.1.D обязан вставлять system username (NSFullUserName / NSUserName) или `""` fallback. Не наша забота в 5.1.A. |
| R3 | ~~Partial index syntax может потребовать GRDB 7 specific API check.~~ | **Resolved** — GRDB 7 поддерживает через `condition:` parameter (`create(index:on:columns:options:condition:)` в `Database+SchemaDefinition.swift:514`). |
| R4 | Контракт §1 говорит "5.1.A spec промоутит контракт в Active". | Header этого spec'а явно фиксирует promote — после approve этого файла контракт считается Active. |
