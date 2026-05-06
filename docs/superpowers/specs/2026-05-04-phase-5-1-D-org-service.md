# Phase 5.1.D — `OrgService.createPersonalOrg` + keystore writers

**Status:** Active (2026-05-05). Fourth sub-project of Phase 5.
**Owner:** Dmitrii.
**Stack:** branches off `feature/phase-5-1-C` (which holds 5.1.A + 5.1.B + 5.1.C commits).

---

## 1. Context

Phase 5.1.D — четвёртая sub-phase Phase 5 ("team presence relay"). Контракт уровня всей фазы — `2026-05-04-phase-5-architecture-contract.md`, §4 (identity model: single-org-per-device), §7 (key lifecycle: teamKey current+history + X25519 long-term), §9 (boundary matrix).

Текущее состояние:

- **5.1.A** landed schema substrate (M006 `org` / M007 `team_members` / M008 `team_keys`) + `TeamMemberRole` enum.
- **5.1.B** landed value types (`Org` / `TeamMember` / `TeamKey`) + 6 GRDB helpers (`upsertOrg` / `readOrg` / `insertTeamMember` / `readTeamMembers` / `insertTeamKey` / `readActiveTeamKey`) inline в `Database.swift`.
- **5.1.C** landed `EnvelopeCodec` real impl (AES-GCM-256) + `EnvelopeHeader.peek` + `ProdEnvelopeCodec` в `LeafCorePrivate/Prod/Crypto/`. Substrate-only, никаких caller'ов.
- **`FileKeyStore`** существующий pattern в `Packages/LeafCore/Sources/LeafCore/Crypto/FileKeyStore.swift` (32B SQLCipher key в `db.key`, mode 0o600, atomic write + read-back verify) — template для нового `TeamKeystore`.
- **`OrganizationView` / `TeamView`** — placeholders (`EmptyStateView(phase: ...)`); реальный UI content приходит в 5.1.E.
- **Composition root** (`Agent.swift`, `MenuBarApp`) — substrate-only mirror 5.1.A/B/C: 5.1.D их не трогает.
- Test targets: `LeafCoreTests` (public) — baseline 691 после 5.1.C.

**Зачем сейчас:** Phase 5.1.A/B/C дали schema + value types + helpers + codec, но никаких rows в трёх новых таблицах ещё не пишется — вся substrate "сухая". 5.1.D ставит первый писатель: domain service `OrgService.createPersonalOrg(displayName:)` + file-based `TeamKeystore` (X25519 priv + per-rotation teamKey файлы). После 5.1.D у нас есть полностью рабочая offline команда (один admin-член, один initial teamKey, X25519 keypair) — но без UI. UI CTA ("Create personal org" + Organization/Team views) + integration test + landing — Phase 5.1.E.

**Источники правды (priority при противоречии):**

1. `2026-05-04-phase-5-architecture-contract.md` — §4 (identity model), §7 (key lifecycle), §9 (boundary matrix).
2. `leaf-docs/docs/03-architecture/presence-relay.md` — public key-management shape.
3. Существующий `Crypto/FileKeyStore.swift` + value types в `Team/` — code-style template.

---

## 2. Scope

### Входит

| Артефакт | Файл | Заметка |
|---|---|---|
| `LeafError.orgAlreadyExists` | `Packages/LeafCore/Sources/LeafCore/LeafError.swift` (edit, +1 case) | Idempotency guard в `createPersonalOrg`; consumers — UI 5.1.E |
| `TeamKeystore` enum-namespace | `Packages/LeafCore/Sources/LeafCore/Crypto/TeamKeystore.swift` (new) | File-based key writer/reader: X25519 priv (32B) + per-rotation teamKey (32B per file, named by UUID). POSIX 0o600. Mirror `FileKeyStore` pattern. |
| `OrgService` struct | `Packages/LeafCore/Sources/LeafCore/Team/OrgService.swift` (new) | Domain service: `createPersonalOrg(displayName:)` + `currentOrg()`. Inject'абельные `now` / `randomBytes` / `randomUUID` / `randomX25519PrivateKey` factories для тестов. |
| Public tests — keystore | `Packages/LeafCore/Tests/LeafCoreTests/TeamKeystoreTests.swift` (new) | 8 tests: round-trip / 0o600 / atomic-overwrite / unknown-id / corrupted / subdir creation |
| Public tests — service | `Packages/LeafCore/Tests/LeafCoreTests/OrgServiceTests.swift` (new) | 12 tests: 3 row writes / file writes / 0o600 / pubkey-priv match / idempotency / trim+empty / injectable randomness round-trip |

### НЕ входит (явно отложено)

- **UI** (`OrganizationView` / `TeamView` real content + "Create personal org" CTA) — **5.1.E** (real call-site первый раз материализует rows в DB при ручном smoke).
- **Composition root в `MenuBarApp` / `Agent.swift`** — **5.1.E** (UI первый caller; никакого dead-injection без consumer'а).
- **Integration test** (`Database` + `OrgService` + `TeamKeystore` + UI launch end-to-end) — **5.1.E**.
- **`docs(shared)` landing commit** на `current-state.md` — **5.1.E** (закрывает 5.1.A→E пятёрку одним landing entry).
- **X25519 ECDH + HKDF-SHA256 helpers** — **5.2** (first call-site = invite handshake, contract §9 deviation note from 5.1.C amendment).
- **Lifecycle mutators** (`markTeamMemberRemoved` / `deprecateTeamKey`) + key rotation — **5.3**.
- **`presence_outgoing` / `presence_history` migrations + WS broadcast loop** — **5.4** (первый реальный consumer `ProdEnvelopeCodec`).
- **Onboarding screen 6** ("Team — join via invite OR create personal org") — **5.5**.
- **Multi-device sync** / migration — never в MVP (single-org-per-device, contract §4).

---

## 3. Public API design

### `Crypto/TeamKeystore.swift`

```swift
import Foundation
import Security

public enum TeamKeystore {
    /// `~/Library/Application Support/Leaf/keystore/` — co-located с `db.key`
    /// (та же subdir что у `DatabasePath`).
    public static func defaultRoot() -> URL

    public static let x25519PrivateFilename = "x25519.priv"
    public static let teamKeysSubdir = "team-keys"
    public static let teamKeyExtension = "key"   // file = "<UUID>.key"

    public static let x25519PrivateLength = 32
    public static let teamKeyLength = 32

    /// Atomic write (`Data.write(to:options:[.atomic])` → POSIX `rename(2)`)
    /// + `setAttributes [.posixPermissions: 0o600]`. Parent dir создаётся
    /// idempotently. Length validation: bytes.count == 32, иначе throws
    /// `LeafError.invalidPayload`.
    public static func writeX25519Private(_ bytes: Data, at root: URL = defaultRoot()) throws

    /// Throws `LeafError.keyFileUnavailable` если файла нет;
    /// `LeafError.keyFileCorrupted` если bytes.count != 32.
    public static func readX25519Private(at root: URL = defaultRoot()) throws -> Data

    /// `id` — `team_keys.id` (UUID lowercase canonical). Файл:
    /// `<root>/team-keys/<id>.key`. Atomic write, mode 0o600, length-validated.
    public static func writeTeamKey(_ bytes: Data, id: String, at root: URL = defaultRoot()) throws

    public static func readTeamKey(id: String, at root: URL = defaultRoot()) throws -> Data

    /// Test/dev only — recursive removeItem на `<root>/`.
    public static func deleteAll(at root: URL = defaultRoot()) throws
}
```

**Internal helpers** (private static, mirror `FileKeyStore`):
- `ensureParentDirectory(for:)` — `createDirectory(withIntermediateDirectories: true)`, ошибка → `LeafError.keyFileUnavailable(reason:)`.
- `writeAtomic(_:to:expectedLength:)` — length-validate input → `Data.write` `.atomic` → `setAttributes` 0o600.
- `readExisting(at:expectedLength:)` — `Data(contentsOf:)` + length guard.

**Зачем enum, а не class:** mirrors `FileKeyStore`, single source of truth API per filesystem location, default-arg `at root: URL` достаточен для test-injection.

### `Team/OrgService.swift`

```swift
import CryptoKit
import Foundation
import Security

public struct OrgService: Sendable {
    private let database: Database
    private let keystoreRoot: URL
    private let now: @Sendable () -> Date
    private let randomBytes: @Sendable (Int) throws -> Data
    private let randomUUID: @Sendable () -> String
    private let randomX25519PrivateKey: @Sendable () -> Curve25519.KeyAgreement.PrivateKey

    public init(
        database: Database,
        keystoreRoot: URL = TeamKeystore.defaultRoot(),
        now: @escaping @Sendable () -> Date = { Date() },
        randomBytes: @escaping @Sendable (Int) throws -> Data = OrgService.secureRandom,
        randomUUID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        randomX25519PrivateKey: @escaping @Sendable () -> Curve25519.KeyAgreement.PrivateKey
            = { Curve25519.KeyAgreement.PrivateKey() }
    )

    /// Idempotency guard на DB-уровне (`readOrg()` first). При наличии — throws
    /// `LeafError.orgAlreadyExists`. Empty/whitespace `displayName` — throws
    /// `LeafError.invalidPayload`.
    ///
    /// На успехе:
    /// - 3 новых row'а в DB (org / team_members.self admin / team_keys.initial)
    /// - 2 keystore-файла (`<root>/x25519.priv` + `<root>/team-keys/<id>.key`)
    /// - returns создан `Org` value type
    public func createPersonalOrg(displayName: String) throws -> Org

    /// Pass-through через `database.readOrg()` — UI 5.1.E использует
    /// для "show CTA only if nil" логики (не должен знать про Database напрямую).
    public func currentOrg() throws -> Org?

    /// Internal — exposed только для default arg `init`'а. 32B CSPRNG.
    static func secureRandom(_ count: Int) throws -> Data
}
```

### Шаги `createPersonalOrg` (sequential, fail-fast)

1. `let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)`; `guard !trimmed.isEmpty else { throw LeafError.invalidPayload }`.
2. `guard try database.readOrg() == nil else { throw LeafError.orgAlreadyExists }`.
3. Generate IDs: `selfMemberID = randomUUID()`, `orgID = randomUUID()`, `teamKeyID = randomUUID()`.
4. Generate keys: `privKey = randomX25519PrivateKey()`, `teamKeyBytes = try randomBytes(TeamKeystore.teamKeyLength)`.
5. **Keystore writes first** (orphan-файл при DB-fail < orphan-row при keystore-fail):
   - `try TeamKeystore.writeX25519Private(privKey.rawRepresentation, at: keystoreRoot)`
   - `try TeamKeystore.writeTeamKey(teamKeyBytes, id: teamKeyID, at: keystoreRoot)`
6. Build value types:
   - `pubkeyHex = privKey.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()` (64 chars).
   - `nowDate = now()`.
   - `member = TeamMember(id: selfMemberID, orgID: orgID, role: .admin, pubkeyHex:, displayName: trimmed, addedAt: nowDate, removedAt: nil)`.
   - `org = Org(id: orgID, name: trimmed, createdAt: nowDate, createdByMemberID: selfMemberID)`.
   - `teamKey = TeamKey(id: teamKeyID, generatedAt: nowDate, deprecatedAt: nil, generatedByMemberID: selfMemberID)`.
7. **DB writes** (порядок per contract §9 list — org → member → team_keys):
   - `try database.upsertOrg(org)` (UPSERT — guard в шаге 2 гарантирует insert path).
   - `try database.insertTeamMember(member)`.
   - `try database.insertTeamKey(teamKey)`.
8. `return org`.

### `LeafError.swift` after edit

```swift
public enum LeafError: Error, Sendable {
    case notImplemented
    case databaseUnavailable
    case keychainUnavailable(OSStatus)
    case keyFileUnavailable(reason: String)
    case keyFileCorrupted
    case corruptedEnvelope
    case invalidPayload
    case jsonEncodingFailed
    case orgAlreadyExists      // NEW
}
```

---

## 4. Design tradeoffs (зафиксировано)

- **Public LeafCore (не Private)** — `TeamKeystore` mirrors `FileKeyStore` (тоже public), `OrgService` оркестрирует public-уровневые primitives (CryptoKit `Curve25519.KeyAgreement` + `SecRandomCopyBytes`). Никаких HKDF info strings / nonce composition / proprietary algos. File paths видны в whitepaper architecture diagram (contract §2 ASCII).
- **Keystore лейаут — DB-driven, не self-pointing.** "Current rotation" = `readActiveTeamKey().id` → `team-keys/<id>.key`. Нет отдельного `current` symlink/pointer — **no split-brain risk** ("DB говорит X, файл-pointer говорит Y"). История = просто все файлы в `team-keys/` (по id). Phase 5.3 rotation добавит новый `<new-id>.key` и обновит `team_keys.deprecated_at_ms` — старый файл остаётся forever (decrypt past presence_history).
- **Keystore-first, DB-second.** Если DB write fail'нёт после keystore write — orphan-файл; recovery от orphan = noop при следующем `createPersonalOrg` (idempotency guard видит `readOrg() == nil` → `.atomic` write поверх существующих файлов → safe). Обратный порядок (DB first) — orphan-row без ключа, decrypt impossible на presence broadcast в 5.4.
- **Strict `.orgAlreadyExists` (не silent idempotent).** UI 5.1.E проверит `currentOrg()` сам и покажет CTA только если nil. Service не permissive — auto-idempotency прятала бы баг "случайно второй вызов из UI". Invite-accept путь (Phase 5.2) — отдельный entrypoint, не reuse `createPersonalOrg`.
- **Inject'абельные factories — `now` / `randomBytes` / `randomUUID` / `randomX25519PrivateKey`.** Standard test-double pattern (FileKeyStore делает это через default-arg `at:`; OrgService нужно глубже — RNG + keypair gen). Test 12 `createPersonalOrg_isInjectable` проверяет deterministic round-trip.
- **No composition root touch.** Substrate-only. UI wiring → 5.1.E. Mirror 5.1.A/B/C discipline.
- **`invalidDisplayName` НЕ добавлен** — переиспользуем `.invalidPayload` (consistent с другими "bad input" сценариями в codebase). Single-case `.orgAlreadyExists` достаточен.
- **`Curve25519.KeyAgreement` (не `Curve25519.Signing`).** Phase 5.2 invite handshake = ECDH wrap'инг teamKey под shared secret (KeyAgreement type). Identity-uniqueness = via UUID `team_members.id`, не via signing key. Single keypair per device для key agreement; signing reserved для possible future identity attestation (out of MVP).

---

## 5. Test plan

### `TeamKeystoreTests.swift` (8 tests, tempDir setUp/tearDown)

Helper: `setUp` создаёт `tempRoot = NSTemporaryDirectory().appendingPathComponent(UUID().uuidString)`; `tearDown` removeItem.

1. `testWriteAndReadX25519Private_RoundTrip` — write 32 random bytes → `readX25519Private` returns same.
2. `testWriteX25519Private_AppliesPosix0600` — после write, `attributesOfItem` `.posixPermissions` & 0o777 == 0o600.
3. `testWriteX25519Private_AtomicOverwrite` — write A → write B → read returns B.
4. `testWriteAndReadTeamKey_RoundTrip` — id="ab12...", write 32 bytes, read returns same.
5. `testWriteTeamKey_AppliesPosix0600` — same posix check для `<root>/team-keys/<id>.key`.
6. `testReadTeamKey_UnknownID_Throws` — `readTeamKey(id: <fresh uuid>)` → `LeafError.keyFileUnavailable`.
7. `testReadX25519Private_Corrupted_Throws` — write 31 bytes raw via `Data.write` (bypass keystore validation), read → `LeafError.keyFileCorrupted`.
8. `testWriteTeamKey_CreatesTeamKeysSubdir` — после write `<root>/team-keys/` directory exists (FileManager isDirectory check).

Bonus (если time permits):
- `testWriteX25519Private_BadInputLength_Throws` — `bytes.count != 32` → `.invalidPayload`.

### `OrgServiceTests.swift` (12 tests, tempDir + tempDB setUp/tearDown)

Helper:
```swift
private func makeTempDB() throws -> (Database, URL)  // returns (db, dbURL)
private func makeService(db: Database, root: URL) -> OrgService
```
Mirror `DatabaseTeamTests` setUp pattern (deterministicTest encryption).

1. `testCreatePersonalOrg_WritesAllThreeRows` — после вызова `db.readOrg() != nil`, `db.readTeamMembers(orgID:)` count == 1, `db.readActiveTeamKey() != nil`. Cross-validate FK chain: `org.createdByMemberID == member.id == teamKey.generatedByMemberID`.
2. `testCreatePersonalOrg_WritesAdminMemberWithSelfPubkey64Chars` — `member.role == .admin`, `member.pubkeyHex.count == 64`, hex regex `^[0-9a-f]{64}$`.
3. `testCreatePersonalOrg_OrgFields` — `org.name == trimmed displayName`, `org.createdByMemberID` matches member.id, `org.createdAt == injected now()`.
4. `testCreatePersonalOrg_TeamKeyFields` — `teamKey.generatedByMemberID == member.id`, `teamKey.deprecatedAt == nil`.
5. `testCreatePersonalOrg_WritesX25519PrivateFile_0600_32B` — `<root>/x25519.priv` exists, 32 bytes, posix 0o600.
6. `testCreatePersonalOrg_WritesTeamKeyFile_0600_32B_NamedByID` — `<root>/team-keys/<teamKey.id>.key` exists, 32 bytes, posix 0o600. Filename uses lowercase UUID.
7. `testCreatePersonalOrg_ThrowsIfAlreadyExists` — second call → throws `LeafError.orgAlreadyExists`. DB row count unchanged (still 1 org / 1 member / 1 teamKey). Keystore files unchanged.
8. `testCreatePersonalOrg_EmptyDisplayName_Throws` — `""` → `.invalidPayload`. `"   "` (whitespace only) → `.invalidPayload`. No DB rows / no keystore files written.
9. `testCreatePersonalOrg_TrimsDisplayName` — input `"  Alice  "` → `org.name == "Alice"`, `member.displayName == "Alice"`.
10. `testCurrentOrg_ReturnsNilBeforeCreate_AndOrgAfterCreate` — round-trip via `currentOrg()`.
11. `testCreatePersonalOrg_X25519_PrivateMatchesPublicKeyDerivation` — read priv from keystore, reconstruct `Curve25519.KeyAgreement.PrivateKey(rawRepresentation:)`, derive `publicKey.rawRepresentation`, hex-encode → equals `member.pubkeyHex`. Catches "wrong key written to file" regression.
12. `testCreatePersonalOrg_IsInjectable` — inject deterministic `randomUUID = { "fixed-uuid-N" }` (counter), `randomBytes = { Data(repeating: 0xAB, count: $0) }`, `randomX25519PrivateKey = { fixedKey }`, `now = { fixedDate }`. Assert конкретные ID / bytes / timestamp в DB + keystore files.

**Target test count:** baseline 691 → ~711 (+8 keystore + +12 service).

---

## 6. Build / verification

- `cd Packages/LeafCore && swift test` — все targets зелёные (LeafCoreTests, LeafCorePrivateTests, LeafMCPProtocolTests).
- `xcodebuild -scheme Leaf build` — все 5 schemes (Leaf / LeafAgent / LeafMCP / LeafCore / LeafCorePrivate) BUILD SUCCEEDED.
- `git diff main..feature/phase-5-1-D -- LeafAgent/Agent.swift Leaf/` пуст (no composition root regression).
- `git status` clean.
- `/pre-push-leaf` clean (no bundle ID presets / точных пороговых чисел / KDF info strings — их и нет).

---

## 7. Commit decomposition

Atomic, sequential, one logical change per commit. Каждый commit оставляет tree green (`swift test` passes).

| # | Commit | Файлы | Why atomic |
|---|---|---|---|
| 1 | `docs(specs): Phase 5.1.D — OrgService + keystore writers spec` | `docs/superpowers/specs/2026-05-04-phase-5-1-D-org-service.md` (this file) | Spec lands first; downstream commits ссылаются на этот doc |
| 2 | `feat(core): Phase 5.1.D — LeafError.orgAlreadyExists` | `Packages/LeafCore/Sources/LeafCore/LeafError.swift` (+1 case) | Single-line enum addition; callers будут в commits 4-5 |
| 3 | `feat(core): Phase 5.1.D — TeamKeystore (X25519 priv + per-rotation teamKey files, 0o600)` | `Crypto/TeamKeystore.swift` (new) + `TeamKeystoreTests.swift` (8 tests) | Self-contained file storage layer; никаких dependencies на OrgService |
| 4 | `feat(core): Phase 5.1.D — OrgService.createPersonalOrg + currentOrg` | `Team/OrgService.swift` (new) + `OrgServiceTests.swift` (12 tests) | Domain service на готовом TeamKeystore + Database helpers |
| 5 | (Stage 7 if needed) post-review tightening commits per `superpowers:code-reviewer` verdict | TBD | Address BLOCKING / N-x findings; deferred non-blocking → 5.1.E carry-over |

Push: после commit 4 — `git push -u origin feature/phase-5-1-D`. Code review запускается на pushed branch. Merge в main — отдельный шаг user'а после review pass + 5.1.E land (5.1.D остаётся substrate без UI; merge целостной 5.1.A→E пятёркой).

---

## 8. Acceptance criteria

- ☐ `LeafError.orgAlreadyExists` case добавлен.
- ☐ `TeamKeystore` enum с 5 public методами (writeX25519Private / readX25519Private / writeTeamKey / readTeamKey / deleteAll); файлы 0o600, atomic write, length-validated.
- ☐ `OrgService` struct с `createPersonalOrg` (3 row writes + 2 keystore files + idempotency guard + trim/empty validation) + `currentOrg()` pass-through.
- ☐ Inject'абельные factories для тестов: `now` / `randomBytes` / `randomUUID` / `randomX25519PrivateKey`.
- ☐ X25519 keypair генерируется через `Curve25519.KeyAgreement.PrivateKey` (CryptoKit); pubkey hex-encoded 64 chars matches priv в keystore.
- ☐ Файловый layout: `<root>/x25519.priv` + `<root>/team-keys/<UUID>.key`; root = `<applicationSupport>/Leaf/keystore/`.
- ☐ DB writes порядок: org → member.admin → team_keys.initial; FK chain consistent (`createdByMemberID == member.id == generatedByMemberID`).
- ☐ Idempotency: second `createPersonalOrg` call throws `.orgAlreadyExists`, не пишет ничего.
- ☐ 20 новых тестов (8 keystore + 12 service); `swift test` зелёный, total ≈711 (baseline 691 + 20).
- ☐ Все 5 xcodebuild schemes BUILD SUCCEEDED.
- ☐ Composition root в Agent.swift / MenuBarApp НЕ изменён (substrate-only).
- ☐ `/pre-push-leaf` clean.
- ☐ Git tree clean.

---

## 9. Open considerations (для review)

- **`writeAtomic` length validation placement.** Spec кладёт `bytes.count == 32` check внутрь `writeAtomic(_:to:expectedLength:)`. Альтернатива — отдельная public guard в `writeX25519Private` / `writeTeamKey`. Решение в commit 3: единая internal helper consolidates discipline; public методы делегируют length constant из `*Length` static.
- **`UUID().uuidString.lowercased()` vs raw bytes для filename.** Spec — lowercase canonical hyphenated form (`abc12345-0000-...`). Alternative — raw 16B hex (32 chars без hyphens). Решение: hyphenated UUID более debuggable + matches `team_keys.id` storage format (Phase 5.1.B helpers пишут UUIDs как-есть из `randomUUID()` callback). Filename injection через `randomUUID` callback тестируется в test 12.
- **Date precision in test 3 (`createPersonalOrg_OrgFields`).** `Date()` имеет sub-millisecond precision; SQLCipher storage = ms (`Int64(timeIntervalSince1970 * 1000)`). Round-trip rounds. Решение: test 3 inject'ит `now` как whole-second Date (consistent с DatabaseTeamTests pattern), сравнение exact-match.
- **`OrgService` thread-safety.** Spec — `Sendable struct` без mutable state. `createPersonalOrg` is throws-blocking; `Database.upsertOrg` etc. блокирующие через `pool.write`. UI 5.1.E будет вызывать с `Task.detached` или via SwiftUI `.task` modifier. Никакой `await` в OrgService API (consistent с FileKeyStore + Database helpers).
- **Equatable comparisons in tests.** Test 1 cross-validates FK chain across 3 value types. `Org` / `TeamMember` / `TeamKey` все Hashable (=> Equatable). Direct `XCTAssertEqual` on whole rows — OK. Date precision rounding handled per consideration выше.

---

*End of spec. Plan file follows in `.claude/plans/phase-5-1-D.md`.*
