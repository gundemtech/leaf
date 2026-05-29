# Phase 5.3.A — Team DB lifecycle mutators (markTeamMemberRemoved / deprecateTeamKey / readTeamKey)

**Status:** Active (2026-05-06). First sub-phase of Phase 5.3 ("member removal + team key rotation").
**Owner:** Alex.
**Stack base:** `feature/phase-5-2-E` (Phase 5.2 closed end-to-end @ 802 SPM tests).
**Branch:** `feature/phase-5-3-A`.

---

## 1. Context

Phase 5.2 закрыл invite handshake — две Mac'и могут поднять одну `org` + одну active `teamKey` через encrypted blob через relay KV. Phase 5.3 закрывает первый mutation lifecycle: admin может remove'нуть member и rotate'нуть teamKey с N-1 pairwise ECDH wraps для оставшихся peers.

Phase 5.3.A — **substrate sub-phase**: только три DB lifecycle helper'а на `team_members` / `team_keys`. Pure SQL + GRDB. Без crypto / wire / UI / orchestration. Mirror'ит роль 5.1.B helpers'а в стеке 5.1 (substrate под последующие orchestrators).

**Зачем сейчас:** 5.3.B (RotationBlobCodec) / 5.3.C (RelayClient extension) / 5.3.D (KeyRotationService orchestrator) / 5.3.E (UI + peer fetch loop) — все нуждаются в этих трёх helper'ах:

- 5.3.D `KeyRotationService.rotate(...)` атомарно: `insertTeamKey(new)` → `deprecateTeamKey(old)` → optional `markTeamMemberRemoved`.
- 5.3.E `RotationFetchService` peer-side: incoming snapshot под previously-rotated `keyID` → `readTeamKey(byID:)` для unwrap path. Forever-retained per architecture contract §12.

**Источники правды (priority при противоречии):**

1. `2026-05-04-phase-5-architecture-contract.md` — §7 Key lifecycle, §10 Failure modes, §12 forever-retained team_keys for past `presence_history` decrypt.
2. Phase 5.3 overview — `.claude/plans/phase-5-3-overview.md` (decomposition в 5 sub-phases).
3. 5.1.B Team helpers (`Database.swift:522-654`) — code-style template.

---

## 2. Scope

### Входит

| Артефакт | Файл | Заметка |
|---|---|---|
| `markTeamMemberRemoved(memberID:at:)` | `Packages/LeafCore/Sources/LeafCore/DB/Database.swift` (extend) | UPDATE c idempotency (silent no-op if already removed) |
| `deprecateTeamKey(keyID:at:)` | `Database.swift` (extend) | UPDATE c sole-active invariant guard + idempotency |
| `readTeamKey(byID:)` | `Database.swift` (extend) | SELECT regardless of deprecated status; reader-mode safe |
| Test suite | `Packages/LeafCore/Tests/LeafCoreTests/DatabaseTeamRemovalTests.swift` (новый) | XCTest, ~14 cases mirror style `DatabaseTeamTests.swift` |

Все три helper'а живут в новой MARK секции `// MARK: - Team lifecycle (Phase 5.3.A)` в `Database.swift`, сразу после существующего `// MARK: - Team (Phase 5.1.B)` блока (строки 522-654).

### НЕ входит (явно отложено в позже sub-phases)

- Никаких `insertTeamKey` extension'ов / `TeamKeystore` mutator'ов — keystore live-extension в 5.3.D.
- `RotationPlaintext` / `RotationBlob` / `RotationBlobCodec` / `RotationKDF` → 5.3.B.
- `RelayClient.postRotationBlob` / `fetchPendingRotations` / `ackRotation` → 5.3.C.
- `KeyRotationService` / `MemberRemovalService` orchestrators + `RotationOutbox` journal → 5.3.D.
- `RotationFetchService` peer-side + `RotationFetchScheduler` polling → 5.3.E.
- UI: TeamView per-row Remove menu, RemoveMemberSheet, RemovedFromTeamBanner → 5.3.E.
- Schema migration changes — M007/M008 columns (`removed_at_ms`, `deprecated_at_ms`) уже есть с 5.1.A. Никаких новых migrations.
- `LeafError` cases — все нужные уже существуют (`databaseUnavailable`, `invalidPayload`).

---

## 3. API surface

```swift
// Packages/LeafCore/Sources/LeafCore/DB/Database.swift
// MARK: - Team lifecycle (Phase 5.3.A)

/// Soft-delete на team_members row. Sets `removed_at_ms = at`. Idempotent
/// re-call на already-removed row preserves original timestamp (silent no-op).
/// Throws `LeafError.invalidPayload` если member не существует.
public func markTeamMemberRemoved(memberID: String, at removedAt: Date) throws

/// Marks team_keys row deprecated. Sets `deprecated_at_ms = at`.
/// **Sole-active invariant:** throws `LeafError.invalidPayload` если
/// deprecating этот key оставит 0 active rows. Caller (5.3.D KeyRotationService)
/// должен `insertTeamKey(new)` first в той же tx.
/// Idempotent re-call на already-deprecated row preserves original timestamp.
/// Throws `LeafError.invalidPayload` если key не существует.
public func deprecateTeamKey(keyID: String, at deprecatedAt: Date) throws

/// Returns team_keys row by id, regardless of deprecated status.
/// Used by 5.3.E peer-side flow для decrypt'а incoming snapshot
/// под previously-rotated keyID (forever-retained per contract §12).
/// Reader-mode safe — read-only API без mode guard.
public func readTeamKey(byID id: String) throws -> TeamKey?
```

---

## 4. Semantics

### 4.1 `markTeamMemberRemoved`

Single transaction (`pool.write`):

1. Mode-guard: `guard mode == .writer else { throw .databaseUnavailable }`.
2. Conditional UPDATE: `UPDATE team_members SET removed_at_ms = ? WHERE id = ? AND removed_at_ms IS NULL` → read `db.changesCount`.
3. Branch on `changesCount`:
   - `1` → success, return.
   - `0` → SELECT row by id (in same tx):
     - Row exists с `removed_at_ms != NULL` → idempotent no-op. Return без error.
     - Row не существует → throw `LeafError.invalidPayload`.

**Why conditional UPDATE + SELECT-on-zero:** дешевле чем upfront SELECT+UPDATE для happy path (один statement vs два); SELECT нужен только в edge cases для disambiguation.

### 4.2 `deprecateTeamKey`

Single transaction (`pool.write`):

1. Mode-guard.
2. **Sole-active invariant guard:** `SELECT count(*) FROM team_keys WHERE deprecated_at_ms IS NULL` → если count `<= 1` → SELECT target row by id:
   - Row exists с `deprecated_at_ms IS NULL` (target itself **is** the sole active — deprecating leaves 0 active) → throw `LeafError.invalidPayload`.
   - Row exists с `deprecated_at_ms != NULL` (target already deprecated — deprecating again is a no-op, doesn't change active count) → bypass guard (continue to step 3 → idempotent no-op path).
   - Row не существует — bypass guard (handled by step 3 zero-changesCount branch — will throw `.invalidPayload`).
3. Conditional UPDATE: `UPDATE team_keys SET deprecated_at_ms = ? WHERE id = ? AND deprecated_at_ms IS NULL` → `changesCount`.
4. Branch:
   - `1` → success.
   - `0` → SELECT row by id:
     - Exists с `deprecated_at_ms != NULL` → idempotent no-op (return success).
     - Missing → throw `LeafError.invalidPayload`.

**Edge case — already-deprecated row + sole active still passes invariant:** если target уже deprecated (`deprecated_at_ms != NULL`), invariant check в step 2 distinguishes "we are not the active one being killed" — count=1 means **another** key is the lone active, deprecating this target (which is already deprecated) — no-op safe.

**Why guard before UPDATE:** UPDATE-then-rollback требует transaction discipline; cheaper to SELECT-then-decide. Step 2 + 3 атомарны через single `pool.write`.

### 4.3 `readTeamKey(byID:)`

Single read (`pool.read`):

1. **No mode-guard** — read-only API (mirror `readActiveTeamKey` / `readOrg`).
2. `SELECT id, generated_at_ms, deprecated_at_ms, generated_by_member_id FROM team_keys WHERE id = ? LIMIT 1` (LIMIT defensive — PK guarantees uniqueness).
3. `flatMap(Self.mapTeamKeyRow)` — reuse existing private static (Database.swift:827).

---

## 5. Implementation notes

**Reuse без modification:**
- `Self.mapTeamKeyRow` (Database.swift:827) — все 4 поля, без changes.
- `Self.mapTeamMemberRow` (Database.swift:805) — для select-on-zero disambiguation путь в `markTeamMemberRemoved`.
- `Schema.TeamMembers.*` / `Schema.TeamKeys.*` (Schema.swift:89-117) — column constants.

**SQL style guidelines (mirror 5.1.B):**
- Multi-line strings с trailing column-list для readability.
- Schema constant interpolation (`\(Schema.TeamMembers.id)`).
- `arguments: [...]` array для prepared statements.
- `Int64(date.timeIntervalSince1970 * 1000)` для epoch ms.

**Transaction discipline:**
- `markTeamMemberRemoved` — single `pool.write { db in ... }` (UPDATE + optional SELECT-on-zero).
- `deprecateTeamKey` — single `pool.write { db in ... }` (count + optional SELECT + UPDATE + optional SELECT-on-zero). Все шаги внутри одной tx чтобы invariant check + UPDATE были атомарны (concurrent insert другой active row между count и UPDATE невозможен — single writer process).
- `readTeamKey` — single `pool.read`.

**Counter-check pattern (alternative considered, rejected):**
- "Просто issue UPDATE и доверять SQLite" — отвергнут потому что caller'у нужно отличать missing-row error от idempotent no-op для surface-level error messaging в 5.3.D orchestrator.

---

## 6. Test matrix

`Packages/LeafCore/Tests/LeafCoreTests/DatabaseTeamRemovalTests.swift` — новый файл, XCTest. Setup mirror `DatabaseTeamTests.swift` (temp dir + `weakDefaults` + `.deterministicTest` encryption + sample fixture helpers).

| # | Test | Что проверяет |
|---|---|---|
| 1 | `testMarkTeamMemberRemoved_HappyPath` | Active member → mark → row's `removed_at_ms` set; partial index `team_members_org_active` excludes (verify через `readTeamMembers(orgID:)` default args) |
| 2 | `testMarkTeamMemberRemoved_IsIdempotent` | Mark twice with different timestamps → row's `removed_at_ms` preserves first call's value (read via `includeRemoved: true`) |
| 3 | `testMarkTeamMemberRemoved_MissingMemberThrowsInvalidPayload` | Mark с non-existent UUID → throws `.invalidPayload`; existing rows untouched |
| 4 | `testMarkTeamMemberRemoved_ReaderModeThrowsDatabaseUnavailable` | Reader-mode DB → throws `.databaseUnavailable` |
| 5 | `testDeprecateTeamKey_HappyPathWithMultipleActive` | 2 active keys → deprecate one → row's `deprecated_at_ms` set; other key remains active (`readActiveTeamKey()` returns the other) |
| 6 | `testDeprecateTeamKey_SoleActiveGuardThrows` | 1 active key → deprecate it → throws `.invalidPayload`; row remains active (`readActiveTeamKey()` still returns it) |
| 7 | `testDeprecateTeamKey_IsIdempotentOnAlreadyDeprecated` | Deprecate already-deprecated row → preserves first `deprecated_at_ms`; не trip'ает sole-active guard даже если single active row есть в системе (deprecating already-deprecated = no-op) |
| 8 | `testDeprecateTeamKey_MissingKeyThrowsInvalidPayload` | Deprecate с non-existent UUID → throws `.invalidPayload` |
| 9 | `testDeprecateTeamKey_ReaderModeThrowsDatabaseUnavailable` | Reader-mode DB → throws `.databaseUnavailable` |
| 10 | `testDeprecateTeamKey_AfterDeprecateLatestActiveReadActiveReturnsOlder` | 2 active keys (older + newer) → deprecate newer → `readActiveTeamKey()` returns older (verifies partial index `team_keys_active` consistency) |
| 11 | `testReadTeamKey_ByIDReturnsActiveRow` | Insert active key → `readTeamKey(byID:)` returns full row with `deprecatedAt == nil` |
| 12 | `testReadTeamKey_ByIDReturnsDeprecatedRow` | Insert + mark deprecated (через `db.writeSQL` raw escape) → `readTeamKey(byID:)` returns row with non-nil `deprecatedAt` |
| 13 | `testReadTeamKey_ByIDReturnsNilForMissing` | Empty DB → `readTeamKey(byID:)` returns nil |
| 14 | `testReadTeamKey_ReaderModeWorks` | Reader-mode DB (после writer setup) → `readTeamKey(byID:)` succeeds (no mode guard) |

**Test count expectation:** baseline 802 → 816 (Δ +14).

**Fixture helpers (in test file):**
- `insertSampleMembers(_:orgID:)` — mirror DatabaseTeamTests.swift:303.
- `insertSampleKeys(_:)` — new helper для 2-active-keys scenarios (для tests #5, #10, #12).

---

## 7. Branching / commits

- **Branch:** `feature/phase-5-3-A` (off `feature/phase-5-2-E`).
- **Commits (atomic per Stage 5 step):**
  1. `docs(specs): Phase 5.3.A — DB lifecycle mutators spec + plan`
  2. `feat(core): Phase 5.3.A — markTeamMemberRemoved + tests`
  3. `feat(core): Phase 5.3.A — deprecateTeamKey + tests (incl. sole-active guard)`
  4. `feat(core): Phase 5.3.A — readTeamKey(byID:) + tests`
  5. `docs(shared): Phase 5.3.A landed — current-state update`
- **Pre-push:** `/pre-push-leaf`. Expected clean — все table/column names уже public (M007/M008 в whitepaper storage.md), никаких SQL bodies / pragma values / crypto bytes.

---

## 8. Whitepaper sync

Phase 5.3.A — pure implementation moat. **Никаких whitepaper updates.**

- `presence-relay.md` уже описывает rotation flow абстрактно (admin removes member → key rotation → N-1 wraps). Column-level mutations / SQL invariants — implementation detail, не уходит в public docs.
- `storage.md` — table list уже отражает `team_members` / `team_keys` с момента 5.1.A landed.
- `changelog.md` — единственное изменение, которое могло бы быть, это краткая запись типа "Phase 5.3.A landed — DB substrate под team rotation". Решение: **отложить changelog entry до Phase 5.3 ship'а в alpha.X** (5.3.E ship-gate). Промежуточные sub-phases в whitepaper changelog не fragmenting'уем — паттерн consistent с 5.1.A-E (не было per-sub-phase changelog entries).

---

## 9. Verification

1. **Build:** `xcodebuild` все 5 schemes (Leaf / LeafAgent / LeafMCP / LeafCore / LeafCorePrivate) — BUILD SUCCEEDED для всех.
2. **SPM tests:** `swift test --package-path Packages/LeafCore` → 816 tests pass (802 + 14 new).
3. **Manual REPL** (опционально, для smoke):
   ```bash
   sqlcipher ~/Library/Application\ Support/Leaf/events.sqlite
   sqlcipher> PRAGMA key = "x'<hex>'";
   sqlcipher> INSERT INTO team_keys (id, generated_at_ms, deprecated_at_ms, generated_by_member_id) VALUES ('test-key-1', 1714000000000, NULL, 'member-self');
   ```
   Then через Swift REPL или unit test `db.deprecateTeamKey(keyID: "test-key-1", at: Date())` should throw (sole active).
4. **Pre-push:** `/pre-push-leaf` → expected clean.

---

## 10. Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | Sole-active guard race — concurrent insert между `count(*)` и `UPDATE`. | Single writer process (Agent), single `pool.write` tx atomic. SQLite WAL serializes writers. **Not a real risk** в текущей arch. |
| R2 | Idempotent no-op скрывает caller-bug "mark removed twice with different intent". | Acceptable trade-off для 5.3.D RotationOutbox crash-resume — outbox iterate peers may re-enter. Caller checks pre-state via `readOrg()` / `readTeamMembers()` если intent matters. |
| R3 | `readTeamKey(byID:)` без mode guard — reader callers могут полагаться без mode awareness. | Intentional — 5.3.E peer fetch service runs в Agent (writer process), но MenuBarApp / MCPServer (readers) могут читать в будущем. Mirror'ит `readOrg` / `readActiveTeamKey` / `readTeamMembers` semantic. |
| R4 | `markTeamMemberRemoved` allows removing the self-admin (last admin) — потенциальный sole-admin lockout. | **Out of 5.3.A scope.** Sole-admin invariant — забота 5.3.D `MemberRemovalService` orchestrator (per overview decomposition). DB-уровень — pure mutation primitive без role logic. |
| R5 | `markTeamMemberRemoved` не валидирует что row принадлежит ожидаемой `orgID` — может remove member из чужой org (single-org-per-device contract говорит что org одна, но invariant DB не enforce'ит). | Acceptable — single-org-per-device на caller'е (5.1.D `OrgService.createPersonalOrg` invariant). 5.3.D orchestrator может добавить pre-check `orgID` matches selfOrgID если потребуется. |

---

## 11. Forward dependencies (mentioned для context, NOT в scope)

- **5.3.B** — `RotationBlobCodec` / `RotationKDF` использует те же `team_keys.id` UUID format'ы как `keyID` discriminator в blob header.
- **5.3.D** — `KeyRotationService.rotate(...)` композирует: `insertTeamKey(new)` → `deprecateTeamKey(old)` → optional `markTeamMemberRemoved` (single `pool.write` tx через 5.3.D-уровень `writeSQL` или новый orchestration helper).
- **5.3.E** — `RotationFetchService` peer-side вызывает `insertTeamKey(new)` + `deprecateTeamKey(old)` после successful unwrap; `readTeamKey(byID:)` для buffered-snapshot decrypt путь.
- **5.4** — `ProdEnvelopeCodec` first real consumer; `database.readTeamKey(byID:)` для incoming snapshot's `keyID` lookup; missing key должен gracefully handle (buffer / skip apply, не crash). Forward-compat note запишется в 5.3.E ship summary.
