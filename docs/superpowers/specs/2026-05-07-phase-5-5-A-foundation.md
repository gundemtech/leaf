# Phase 5.5.A — Foundation: `JoinCode` + `InviteURL` + M010 `pending_invites`

**Status:** Active (2026-05-07). First sub-phase of Phase 5.5 stack.
**Owner:** Alex.
**Stack:** branches off `main` (Phase 5.3 stack landed alpha.10 + alpha.11 patch — 5.5 не stack'ится поверх pending PR).

---

## 1. Context

Phase 5.5.A — substrate-only sub-phase, открывает Phase 5.5 stack ("onboarding & team UX polish"). Декомпозиция и cross-phase invariants — `2026-05-06-phase-5-5-decomposition.md` (D1–D10 решения, §4.1–§4.7 invariants). Контракт уровня всей Phase 5 — `2026-05-04-phase-5-architecture-contract.md` §4 (identity), §6 (envelope), §8 (relay API surface — 5.5 НЕ расширяет).

**Зачем сейчас:** Phase 5.5.B/C хотят полный invite-flow rewrite (deep-link, single share-link, pending list в TeamView, three-way onboarding). Чтобы избежать однофазного monolith'а и иметь sub-rollback granularity, 5.5.A landит types-only foundation: human-readable Join code formatter, deep-link URL value type, M010 `pending_invites` table + CRUD store. Никакого UI / wiring / service-layer integration — это 5.5.B (UX surface) и 5.5.C (pending integration).

Текущее состояние:
- **5.3 stack closed** (alpha.10 ship + alpha.11 patch `NSFullUserName`). 860 SPM tests baseline. 20 SQLCipher tables (M001–M009 + presence_state M005). M009 `rotation_outbox` — последняя миграция; M010 next.
- **Existing invite primitives** (5.2.A–E): X25519 identity (`IdentityService.ensureLocalIdentity`), HKDF-SHA256 wrap (`ProdInviteKDF` moat), `InviteBlobCodec` AES-GCM, `RelayClient` HTTP, 24h token + 6-digit OTP exchange. Wire format: invitee shares 64-char hex pubkey OOB; admin shares 32-char base64url token + 6-digit OTP separately. Это и есть UX target для humanization (D3) + single deep-link consolidation (D4).
- **Crypto module** в `Packages/LeafCore/Sources/LeafCore/Crypto/` содержит 8 файлов (Envelope, IdentityService, KeyAgreement, KeyDerivation, RotationBlobCodec, RotationKDF, FileKeyStore, KeychainKeyStore, TeamKeystore). **Нет** существующих base32/Crockford/CRC32 helpers — net-new в 5.5.A.
- **URL scheme registration** не существует в Info.plist. 5.5.A добавляет только value type — Info.plist `CFBundleURLTypes` регистрация — 5.5.B.

**Источники правды (priority при противоречии):**
1. `2026-05-04-phase-5-architecture-contract.md` §4, §6, §8.
2. `2026-05-06-phase-5-5-decomposition.md` §4 (cross-phase invariants — wire format §4.3, URL format §4.4, schema §4.2, file layout §4.1, error cases §4.6).
3. Существующие patterns: `Crypto/Envelope.swift` (codec protocol style), `Migrations/M009_RotationOutbox.swift` (migration extension pattern), `Storage/PresenceStateWriter.swift` (static-method struct CRUD style на `GRDB.Database` handle).

---

## 2. Scope

### Входит

| Артефакт | Файл | Заметка |
|---|---|---|
| `JoinCode` enum-namespace | `Packages/LeafCore/Sources/LeafCore/Crypto/JoinCode.swift` (new) | `static func encode(pubkey: Data) throws -> String` (32-byte X25519 → 77-char formatted). `static func decode(_ s: String) -> Result<Data, JoinCodeError>` (formatted → 32-byte, lenient hex auto-fallback). Pure value type, no DI. |
| `InviteURL` enum-namespace | `Packages/LeafCore/Sources/LeafCore/URLScheme/InviteURL.swift` (new) | `static func compose(token: String, otp: String) -> URL`, `static func parse(_ url: URL) -> Result<(token: String, otp: String), InviteURLError>`. `URLScheme/` directory создаётся в этой sub-phase. |
| `M010_PendingInvites` migration | `Packages/LeafCore/Sources/LeafCore/Migrations/M010_PendingInvites.swift` (new) | `extension DatabaseMigrator { mutating func registerMigration010PendingInvites() }`. Mirror M009 pattern: `CREATE TABLE IF NOT EXISTS pending_invites (...)` per §4.2 + `idx_pending_invites_status` index. |
| `Schema.PendingInvites` constants | `Packages/LeafCore/Sources/LeafCore/Storage/Schema.swift` (edit OR new section) | Mirror `Schema.RotationOutbox`: tableName, column-name constants. Hosts site for index name. |
| Migration registration | `Packages/LeafCore/Sources/LeafCore/Database.swift` (edit) | Insert `migrator.registerMigration010PendingInvites()` после M009 line ~47. |
| `PendingInviteStatus` enum | `Packages/LeafCore/Sources/LeafCore/Storage/PendingInviteStatus.swift` (new) | `public enum PendingInviteStatus: String, Codable, Sendable, CaseIterable { case pending, consumed, expired, revoked, failed }`. rawValue == TEXT в DB (lowercase). |
| `PendingInvite` row struct | `Packages/LeafCore/Sources/LeafCore/Storage/PendingInvite.swift` (new) | `public struct PendingInvite: Sendable, Equatable { token, otp, inviteePubkeyHex, inviteeDisplayNameHint?, createdAtMs, expiresAtMs, status, lastPolledAtMs? }`. Plain struct, не GRDB `Record`. |
| `PendingInvitesStore` CRUD | `Packages/LeafCore/Sources/LeafCore/Storage/PendingInvitesStore.swift` (new) | `public struct PendingInvitesStore: Sendable` со static methods (см. §3.5). Mirror `PresenceStateWriter` pattern — receives `GRDB.Database` handle, throws on error, no transaction management (caller wraps в `Database.write`). |
| `LeafError` additions | `Packages/LeafCore/Sources/LeafCore/Errors/LeafError.swift` (edit) | 3 новых case: `joinCodeMalformed`, `joinCodeChecksumMismatch`, `inviteURLMalformed`. Flat enum, no associated values. |
| `JoinCodeError` enum | (внутри `JoinCode.swift`) | `public enum JoinCodeError: Error, Sendable { case malformed, checksumMismatch }`. Maps к LeafError на call-site (callers wrap по необходимости). |
| `InviteURLError` enum | (внутри `InviteURL.swift`) | `public enum InviteURLError: Error, Sendable { case malformed }`. Maps к LeafError на call-site. |
| Tests — `JoinCodeTests` | `Packages/LeafCore/Tests/LeafCoreTests/JoinCodeTests.swift` (new) | 10 tests (§5.1). |
| Tests — `InviteURLTests` | `Packages/LeafCore/Tests/LeafCoreTests/InviteURLTests.swift` (new) | 6 tests (§5.2). |
| Tests — `M010PendingInvitesTests` | `Packages/LeafCore/Tests/LeafCoreTests/Migrations/M010PendingInvitesTests.swift` (new) | 3 tests (§5.3). |
| Tests — `PendingInviteStatusTests` | `Packages/LeafCore/Tests/LeafCoreTests/PendingInviteStatusTests.swift` (new) | 2 tests (§5.4). |
| Tests — `PendingInvitesStoreTests` | `Packages/LeafCore/Tests/LeafCoreTests/PendingInvitesStoreTests.swift` (new) | 8 tests (§5.5). |

### НЕ входит (явно отложено)

- **Info.plist `CFBundleURLTypes` registration** — 5.5.B. 5.5.A только value type.
- **`InviteURLHandler`** (NSAppleEventManager + applicationDidBecomeActive clipboard hookup) — 5.5.B.
- **`PendingInvitesReader`** Observable — 5.5.C.
- **`InviteService` accept JoinCode parsing path / `InviteAcceptService` JoinCode path** — 5.5.B. 5.5.A не трогает service-layer.
- **`RelayClient` extensions** (HEAD endpoint) — Phase 5.6 (cross-repo).
- **UI rewrites** (`AcceptInviteSheet`, `GenerateInviteSheet`, `OnboardingView .team` step, `TeamView.PendingInvitesSection`) — 5.5.B/C.
- **Composition root wiring в Agent.swift / LeafApp.swift** — substrate-only mirror 5.1.A discipline.
- **5.5.B / 5.5.C `LeafError` cases** (`inviteAlreadyConsumed`, `pasteboardEmpty`, `clipboardNoMatch`, `pendingInviteNotFound`, `pendingInviteAlreadyRevoked`) — добавляются в их sub-phases по мере появления callers.

---

## 3. Public API design

### 3.1 `Crypto/JoinCode.swift`

```swift
import Foundation

public enum JoinCode {
    /// Encode 32-byte X25519 pubkey → 77-char human-readable formatted string.
    /// Wire: XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX-YYYY
    /// 8 groups × 8 chars data (= 64 chars carrying 32 bytes pubkey + 8 zero-pad bytes,
    /// base32-Crockford alphabet excluding I/L/O/U), trailing 4-char checksum
    /// (low 20 bits CRC32-IEEE over raw pubkey, base32-Crockford encoded).
    /// 8 hyphens between 9 groups. Total visible = 77 chars.
    /// Throws `JoinCodeError.malformed` if pubkey.count != 32.
    public static func encode(pubkey: Data) throws -> String

    /// Decode formatted (or legacy hex) string → 32-byte X25519 pubkey.
    /// Strict path: 64+4 base32-Crockford chars + checksum match.
    /// Lenient fallback (D10): exactly 64 hex chars (case-insensitive),
    /// no checksum verify, logs `os_log(.warning)` "legacy hex JoinCode accepted".
    /// Otherwise: `.failure(.malformed)` или `.failure(.checksumMismatch)`.
    public static func decode(_ raw: String) -> Result<Data, JoinCodeError>
}

public enum JoinCodeError: Error, Sendable, Equatable {
    case malformed
    case checksumMismatch
}
```

### 3.2 `URLScheme/InviteURL.swift`

```swift
import Foundation

public enum InviteURL {
    /// Compose `leaf://invite/<token>#<otp>`.
    /// token: existing 32-char base64url из 5.2.D (no validation here — pass-through).
    /// otp: existing 6-digit string из 5.2.D (no validation here).
    public static func compose(token: String, otp: String) -> URL

    /// Strict parser. Validates: scheme=="leaf", host=="invite",
    /// path=="/{token}" non-empty, fragment=="{otp}" non-empty.
    /// Token format check: base64url alphabet, 32 chars exactly.
    /// OTP format check: ASCII digits, 6 chars exactly.
    /// Any deviation → `.failure(.malformed)`.
    public static func parse(_ url: URL) -> Result<(token: String, otp: String), InviteURLError>
}

public enum InviteURLError: Error, Sendable, Equatable {
    case malformed
}
```

### 3.3 `Migrations/M010_PendingInvites.swift`

```swift
import GRDB

public extension DatabaseMigrator {
    mutating func registerMigration010PendingInvites() {
        registerMigration("010_pending_invites") { db in
            try db.create(table: Schema.PendingInvites.tableName, ifNotExists: true) { t in
                t.column(Schema.PendingInvites.token, .text).primaryKey().notNull()
                t.column(Schema.PendingInvites.otp, .text).notNull()
                t.column(Schema.PendingInvites.inviteePubkeyHex, .text).notNull()
                t.column(Schema.PendingInvites.inviteeDisplayNameHint, .text)
                t.column(Schema.PendingInvites.createdAtMs, .integer).notNull()
                t.column(Schema.PendingInvites.expiresAtMs, .integer).notNull()
                t.column(Schema.PendingInvites.status, .text).notNull()
                    .defaults(to: PendingInviteStatus.pending.rawValue)
                t.column(Schema.PendingInvites.lastPolledAtMs, .integer)
            }
            try db.create(
                index: Schema.PendingInvites.indexStatus,
                on: Schema.PendingInvites.tableName,
                columns: [Schema.PendingInvites.status],
                ifNotExists: true
            )
        }
    }
}
```

### 3.4 `Storage/Schema.swift` (extension)

```swift
public extension Schema {
    enum PendingInvites {
        public static let tableName = "pending_invites"
        public static let token = "token"
        public static let otp = "otp"
        public static let inviteePubkeyHex = "invitee_pubkey_hex"
        public static let inviteeDisplayNameHint = "invitee_display_name_hint"
        public static let createdAtMs = "created_at_ms"
        public static let expiresAtMs = "expires_at_ms"
        public static let status = "status"
        public static let lastPolledAtMs = "last_polled_at_ms"

        public static let indexStatus = "idx_pending_invites_status"
    }
}
```

### 3.5 `Storage/PendingInvitesStore.swift`

```swift
import GRDB
import Foundation

public struct PendingInvitesStore: Sendable {
    /// Insert new pending invite row. Throws if token already exists (UNIQUE PK).
    public static func insert(_ row: PendingInvite, in db: GRDB.Database) throws

    /// Read single row by PK token. Returns nil if not found.
    public static func read(token: String, in db: GRDB.Database) throws -> PendingInvite?

    /// Read all rows (status nil = no filter), ordered by created_at_ms DESC.
    public static func readAll(
        status: PendingInviteStatus? = nil,
        in db: GRDB.Database
    ) throws -> [PendingInvite]

    /// Update status atomically. No-op (returns silently) if token not found.
    public static func updateStatus(
        token: String,
        status: PendingInviteStatus,
        in db: GRDB.Database
    ) throws

    /// Update last_polled_at_ms. No-op if token not found.
    public static func updateLastPolledAt(
        token: String,
        atMs: Int64,
        in db: GRDB.Database
    ) throws

    /// Hard delete row. No-op if not found.
    public static func delete(token: String, in db: GRDB.Database) throws
}
```

### 3.6 `Storage/PendingInvite.swift`

```swift
public struct PendingInvite: Sendable, Equatable {
    public let token: String
    public let otp: String
    public let inviteePubkeyHex: String
    public let inviteeDisplayNameHint: String?
    public let createdAtMs: Int64
    public let expiresAtMs: Int64
    public let status: PendingInviteStatus
    public let lastPolledAtMs: Int64?

    public init(
        token: String,
        otp: String,
        inviteePubkeyHex: String,
        inviteeDisplayNameHint: String? = nil,
        createdAtMs: Int64,
        expiresAtMs: Int64,
        status: PendingInviteStatus = .pending,
        lastPolledAtMs: Int64? = nil
    )
}
```

### 3.7 `Storage/PendingInviteStatus.swift`

```swift
public enum PendingInviteStatus: String, Codable, Sendable, CaseIterable {
    case pending
    case consumed
    case expired
    case revoked
    case failed
}
```

### 3.8 `LeafError` additions

```swift
// Existing cases + 3 new:
case joinCodeMalformed
case joinCodeChecksumMismatch
case inviteURLMalformed
```

---

## 4. Wire format details (locked)

### 4.1 `JoinCode` encode pipeline

Input: `pubkey: Data` (must be 32 bytes; throws `.malformed` otherwise).

1. **Pad:** `padded = pubkey + Data(repeating: 0x00, count: 8)` → 40 bytes.
2. **Base32-Crockford encode** (`alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"`, no padding char): 40 bytes × 8 bits = 320 bits → 320 / 5 = 64 chars exactly.
3. **CRC32:** compute CRC32-IEEE (poly `0xEDB88320`, init `0xFFFFFFFF`, output XOR `0xFFFFFFFF`) over **raw 32-byte pubkey** (NOT over padded). Truncate to low 20 bits: `crc & 0x000FFFFF`.
4. **Encode checksum:** 20 bits → 4 base32-Crockford chars (big-endian: highest-5 bits = first char).
5. **Group + hyphenate:** split data 64 chars in 8 groups × 8 chars; append checksum 4 chars as 9th group. Join with `-`.

Output: 77-char string.

### 4.2 `JoinCode` decode pipeline

Input: `raw: String`.

1. **Canonicalize:** strip ASCII whitespace, strip `-`, uppercase. Map base32-Crockford typo-resilience: `O→0`, `I→1`, `L→1` (per Crockford spec). After this `canonical: String`.

2. **Lenient hex fallback check:** if `canonical.count == 64` AND every char ∈ `[0-9A-F]` AND _no_ valid base32-Crockford strict parse below succeeds, decode hex → return 32 bytes + `os_log(.warning, "legacy hex JoinCode accepted (alpha.9-11 compat)")`.

3. **Strict path:** if `canonical.count == 68` (64 data + 4 checksum) AND every char ∈ alphabet:
   - First 64 chars → base32-Crockford decode → 40 bytes.
   - Verify last 8 bytes == `0x00 × 8`. Mismatch → `.failure(.malformed)`.
   - Take first 32 bytes → `pubkey`.
   - Recompute CRC32 over pubkey, truncate low 20 bits, encode 4 base32-Crockford chars → expected.
   - If actual checksum ≠ expected → `.failure(.checksumMismatch)`.
   - Else → `.success(pubkey)`.

4. **Fallback ordering rule:** strict tried first; if length matches lenient (64) AND hex regex passes AND strict fails parsing (because 64 chars can't fit strict-format which needs 68), drop to lenient. Single `decode` API — caller не выбирает.

5. **Otherwise:** `.failure(.malformed)`.

**Why low 20 bits CRC32:** 4 base32 chars carry exactly 20 bits. Collision probability for typo ≈ 1/2²⁰ ≈ 9.5×10⁻⁷ — sufficient for typo detection. JoinCode не cryptographic integrity primitive; MITM на OOB-канале покрывается OTP+pubkey-roundtrip flow в InviteBlobCodec, not JoinCode checksum.

### 4.3 `InviteURL` format

```
leaf://invite/<token>#<otp>
```

- `scheme = "leaf"` strict.
- `host = "invite"` strict (per-action discriminator; `leaf://join/`, `leaf://present/` reserved).
- `path = "/{token}"` где `token` matches `^[A-Za-z0-9_-]{32}$` (base64url, fixed length per 5.2.D contract).
- `fragment = "{otp}"` где `otp` matches `^[0-9]{6}$`.

`compose` builds через `URLComponents` для proper percent-encoding (хотя token+otp фиксированных alphabets, no encoding нужно — но конструктор URL'а через `URLComponents` безопасный default).

`parse` strict — любое отклонение (extra path component, query string, mismatched alphabet, missing fragment) → `.failure(.malformed)`.

### 4.4 M010 schema (per decomposition §4.2)

```sql
CREATE TABLE IF NOT EXISTS pending_invites (
  token                       TEXT PRIMARY KEY NOT NULL,
  otp                         TEXT NOT NULL,
  invitee_pubkey_hex          TEXT NOT NULL,
  invitee_display_name_hint   TEXT,
  created_at_ms               INTEGER NOT NULL,
  expires_at_ms               INTEGER NOT NULL,
  status                      TEXT NOT NULL DEFAULT 'pending',
  last_polled_at_ms           INTEGER
);
CREATE INDEX IF NOT EXISTS idx_pending_invites_status
  ON pending_invites(status);
```

**OTP at rest:** acceptable per decomposition §4.2 — same SQLCipher DB рядом с teamKey, no incremental risk.

---

## 5. Test plan

### 5.1 `JoinCodeTests` (10 tests)

1. `testEncodeDecode_RoundTripsRandomPubkey` — generate 32 random bytes, encode → decode → assert equal.
2. `testEncode_ProducesExpected77CharShape` — assert length == 77, hyphen positions [8, 17, 26, 35, 44, 53, 62, 71], 9 groups (8 of 8 chars + 1 of 4 chars).
3. `testEncode_ThrowsForNon32ByteInput` — try `encode(pubkey: Data(count: 31))` → `.malformed`. Same for 33 bytes, empty.
4. `testDecode_AcceptsMixedCaseAndExtraHyphens` — encode, lowercase + extra hyphens вставлены → decode успешен (canonicalization).
5. `testDecode_TypoResiliencyOIL1` — encode, замена `0`→`O`, `1`→`I`, `1`→`L` в data chars → decode успешен.
6. `testDecode_ChecksumMismatchOnByteFlip` — encode, flip 1 bit в data char → decode → `.checksumMismatch`.
7. `testDecode_PaddingTamperRejected` — encode, replace last 4 data chars (часть padding region) so non-zero bytes appear in last 8 → decode → `.malformed`.
8. `testDecode_LegacyHexAccepted` — generate 32 bytes, hex-encode (lowercase + uppercase mix) → `decode` → `.success`, equal pubkey.
9. `testDecode_LegacyHexWrongLengthRejected` — 63 hex chars → `.malformed`. 65 hex chars → `.malformed`.
10. `testDecode_RejectsEmptyAndGarbage` — empty string, "abc", "XXXX-YYYY", random non-alphabet chars → `.malformed`.

### 5.2 `InviteURLTests` (6 tests)

1. `testComposeParse_RoundTrip` — token=32-char base64url + otp=6 digits → compose → parse → assert equal.
2. `testParse_RejectsWrongScheme` — `https://invite/<token>#<otp>` → `.malformed`.
3. `testParse_RejectsWrongHost` — `leaf://join/<token>#<otp>` → `.malformed`.
4. `testParse_RejectsMissingFragment` — `leaf://invite/<token>` → `.malformed`.
5. `testParse_RejectsMalformedToken` — token со spaces/non-base64url chars → `.malformed`. Token не 32 chars → `.malformed`.
6. `testParse_RejectsMalformedOTP` — fragment "12345" (5 digits) → `.malformed`. Fragment "abcdef" → `.malformed`. Fragment empty → `.malformed`.

### 5.3 `M010PendingInvitesTests` (3 tests)

1. `testM010_CreatesTableAndIndex` — open DB через `Database.openForWrite(at:..., config: .weakDefaults, encryption: .deterministicTest)`, query `sqlite_master` для `pending_invites` table + `idx_pending_invites_status` index → assert exist.
2. `testM010_IsIdempotentOnReopen` — open, close, reopen — миграции re-run без crash. Insert row до reopen, assert preserved.
3. `testM010_FullSequenceRunsCleanly` — open fresh DB → assert все M001-M010 миграции applied (query `grdb_migrations` table — applied versions list).

### 5.4 `PendingInviteStatusTests` (2 tests)

1. `testRawValueStability` — assert `.pending.rawValue == "pending"`, `.consumed.rawValue == "consumed"`, `.expired.rawValue == "expired"`, `.revoked.rawValue == "revoked"`, `.failed.rawValue == "failed"`. Pin lowercase TEXT contract.
2. `testCaseIterableCovers5Cases` — `PendingInviteStatus.allCases.count == 5`.

### 5.5 `PendingInvitesStoreTests` (8 tests)

1. `testInsertAndRead` — insert sample row, read by token → assert equal.
2. `testReadMissingReturnsNil` — read non-existent token → nil.
3. `testInsertDuplicateTokenThrows` — insert one, insert another row with same token → throws.
4. `testReadAllUnfiltered` — insert 3 rows (different statuses), `readAll(status: nil)` → [3 rows] ordered by createdAtMs DESC.
5. `testReadAllFilteredByStatus` — insert 2 pending + 1 consumed, `readAll(status: .pending)` → 2 rows.
6. `testUpdateStatusPersists` — insert pending, updateStatus(.consumed), read → assert status == .consumed.
7. `testUpdateLastPolledAtPersists` — insert (lastPolledAtMs=nil), updateLastPolledAt(123), read → assert == 123.
8. `testDelete` — insert, delete, read → nil. Delete non-existent token → no-op (doesn't throw).

**Total new tests:** 29. Baseline 860 → 889 после 5.5.A. (decomposition §4.7 estimated ≈885; 889 в acceptable range.)

---

## 6. Test target conventions

- **Framework:** XCTest (mirror existing). No Swift Testing macros.
- **DB tests:** `setUp() async throws` создаёт `tempDir` через `FileManager.default.temporaryDirectory.appendingPathComponent("leaf-5-5-A-\(UUID().uuidString)", isDirectory: true)`; `tearDown() async throws` удаляет. `Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)`. Writes через `db.write { ... }` блок, store calls — внутри block.
- **Value-type tests:** plain XCTestCase без DB setup.
- **Helpers:** mirror `DatabaseIntegrationTests.swift` setup pattern.

---

## 7. Acceptance criteria

5.5.A считается closed когда:

1. `swift test --package-path Packages/LeafCore` — green, count = 889 (или ±5 как baseline drift).
2. `xcodebuild -scheme LeafCore -configuration Debug build` — SUCCESS.
3. `xcodebuild -scheme Leaf -configuration Debug build` — SUCCESS (untouched UI re-compiles cleanly poверх migration site changes в Database.swift).
4. `xcodebuild -scheme LeafAgent -configuration Debug build` — SUCCESS.
5. `xcodebuild -scheme LeafMCP -configuration Debug build` — SUCCESS.
6. `xcodebuild -scheme LeafCorePrivate -configuration Debug build` — SUCCESS (no moat changes in 5.5.A but smoke check).
7. Branch `feature/phase-5-5-A-foundation` пушнут на origin. **Не merged в main** — stack под 5.5.B.
8. Independent code review (Stage 6) — APPROVED или APPROVED-WITH-NITS (no blockers).
9. `current-state.md` обновлён в финальном commit (отдельный `docs(shared): Phase 5.5.A landed`).

---

## 8. Out of scope для 5.5.A (carry-overs)

| Excluded | Reserved for |
|---|---|
| Info.plist `CFBundleURLTypes` registration | 5.5.B |
| `InviteURLHandler` (NSAppleEventManager + clipboard auto-detect) | 5.5.B |
| `InviteService` accept-JoinCode parsing path | 5.5.B |
| `InviteAcceptService` accept-JoinCode parsing path | 5.5.B |
| Onboarding `.team` step rewrite (three-way) | 5.5.B |
| `AcceptInviteSheet` rewrite (auto-fill from URL/clipboard) | 5.5.B |
| `GenerateInviteSheet` rewrite (paste Join code OR send template) | 5.5.B |
| `ShareTemplateButton` (Mail/Messages/Copy) | 5.5.B |
| `PendingInvitesReader` Observable + manual [Refresh] | 5.5.C |
| `PendingInvitesSection` + `PendingInviteRow` в TeamView | 5.5.C |
| `RelayClient` HEAD endpoint + auto-poll | Phase 5.6 (cross-repo leaf-relay) |
| Bitwarden-style admin-confirm gate (5-word phrase) | Phase 5.7 candidate |
| 5.5.B/C `LeafError` cases | их sub-phases |

---

## 9. Risks + mitigations

| Risk | Mitigation |
|---|---|
| **Base32-Crockford alphabet typo** (например, swap `V`/`U` — `U` исключён) | Lookup table tests (test 5.1.10 covers reject of non-alphabet); explicit `static let alphabet` constant с test pinning expected 32 chars. |
| **CRC32 polynomial mismatch** (PKZIP IEEE vs Castagnoli) | Test 5.1.6 pin specific known-vector (encode known pubkey, assert exact 4-char checksum literal). Catches accidental Castagnoli switch. |
| **Endianness в low-20-bit truncation** | Document explicitly "low 20 bits = `crc & 0x000FFFFF`, encoded big-endian (highest 5-bit nibble first)". Test 5.1.6 fixed-vector pins. |
| **M010 conflict с M009 ordering** | M009 stays last в Database.swift до M010 insertion. Test 5.3.3 verifies sequence M001-M010 applies clean. |
| **GRDB column-type mapping для INTEGER → Int64** | Mirror existing M009 `Schema.RotationOutbox.createdAtMs` column type — `.integer` GRDB type maps to Int64 в Swift. |
| **Status-column DEFAULT enforcement** | M010 `.defaults(to: PendingInviteStatus.pending.rawValue)` — но row struct `init` уже defaults `status: .pending`. Двойная защита. |
| **Lenient hex case-sensitivity** | Test 5.1.8 explicitly mixes upper+lower case hex chars. Canonical uppercase-pre-decode. |
| **Padding bytes invariant skipped в spec** | §4.1 step 4 explicit "verify last 8 bytes == 0". Test 5.1.7 covers tamper. |

---

## 10. Verification

```bash
cd ~/Desktop/Leaf/leaf/Packages/LeafCore && swift test
# Expect: 889 tests pass (860 baseline + 29 new)

cd ~/Desktop/Leaf/leaf
xcodebuild -scheme LeafCore        -configuration Debug build  # SUCCESS
xcodebuild -scheme LeafCorePrivate -configuration Debug build  # SUCCESS
xcodebuild -scheme Leaf            -configuration Debug build  # SUCCESS
xcodebuild -scheme LeafAgent       -configuration Debug build  # SUCCESS
xcodebuild -scheme LeafMCP         -configuration Debug build  # SUCCESS
```

Pre-push: `/pre-push-leaf` (no moat в 5.5.A — JoinCode encoding details public, M010 schema public, store CRUD public; sanity check all clear).

---

## 11. Dependencies on prior phases

- **5.2.A** `IdentityService` — provides 32-byte X25519 pubkey shape (consumed by JoinCode `encode`).
- **5.2.D** invite token format — 32-char base64url (consumed by InviteURL `compose`/`parse`).
- **5.2.D** OTP format — 6-digit ASCII (consumed by InviteURL).
- **5.1.A** `Schema` namespace + `DatabaseMigrator` extension pattern (M001-M008 mirror).
- **5.3.A** M009 idempotency pattern (M010 mirror).

No prior-phase code edits в 5.5.A (только Database.swift line for M010 registration).

---

*End of Phase 5.5.A spec. Plan — `.claude/plans/phase-5-5-A.md`.*
