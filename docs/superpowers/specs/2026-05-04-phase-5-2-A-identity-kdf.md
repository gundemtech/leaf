# Phase 5.2.A — `IdentityService` + `KeyAgreement` + `InviteKDF` (HKDF-SHA256)

**Status:** Active (2026-05-05). First sub-phase of Phase 5.2 stack.
**Owner:** Alex.
**Stack:** branches off `feature/phase-5-1-E` pending 5.1.A→E unified merge to main.

---

## 1. Context

Phase 5.2.A — substrate-only sub-phase, открывает Phase 5.2 stack ("invite handshake"). Декомпозиция и cross-phase invariants — `2026-05-04-phase-5-2-decomposition.md`. Контракт уровня всей фазы — `2026-05-04-phase-5-architecture-contract.md` §4 (identity model: long-term X25519 keypair "generated at first app run"), §6 (envelope), §7 (key lifecycle), §9 row 5.2 (deviation от 5.1.C — "X25519 ECDH + HKDF-SHA256 helpers переехали в 5.2 row, потому что first real call-site = invite handshake").

Текущее состояние:
- **5.1.A-E** stack closed: schema (M006-M008) + value types + helpers + `EnvelopeCodec`/`ProdEnvelopeCodec` AES-GCM-256 + `OrgService.createPersonalOrg` + `TeamKeystore` (X25519 priv + per-rotation teamKey файлы 0o600) + `OrgReader`/`OrganizationView`/`TeamView` + persistence E2E test.
- **`OrgService.createPersonalOrg`** в 5.1.D генерирует X25519 keypair *inline* (через `randomX25519PrivateKey` injectable factory) и записывает в keystore. Это работает для admin (создателя org), но **invitee** не проходит этот путь — у invitee нет org до accept'а, а X25519 keypair нужен раньше (для admin'а wrap'нуть blob под invitee pub).
- **CryptoKit** API в codebase используется (5.1.C `ProdEnvelopeCodec` AES-GCM, 5.1.D `Curve25519.KeyAgreement.PrivateKey()` в OrgService). HKDF — net-new в 5.2.A.
- Test targets: `LeafCoreTests` (public) baseline 714 после 5.1.E.

**Зачем сейчас:** 5.2.A разбирает identity-bootstrap fragmentation (admin делает inline в createPersonalOrg, invitee сейчас никак) — выносит в shared `IdentityService.ensureLocalIdentity()` + добавляет ECDH wrapper + HKDF protocol/impl. Substrate под 5.2.B `ProdInviteBlobCodec`, который использует ECDH+HKDF для wrap'а teamKey в invite blob.

**Источники правды (priority при противоречии):**
1. `2026-05-04-phase-5-architecture-contract.md` §4, §6, §7.
2. `2026-05-04-phase-5-2-decomposition.md` §4 (cross-phase invariants — wire format, file layout, HKDF derivation shape).
3. Существующие patterns: `Crypto/TeamKeystore.swift` (atomic write 0o600), `Team/OrgService.swift` (factory injection idiom), `Crypto/Envelope.swift` (codec protocol style + `Unimplemented*` placeholder).

---

## 2. Scope

### Входит

| Артефакт | Файл | Заметка |
|---|---|---|
| `IdentityService` enum-namespace | `Packages/LeafCore/Sources/LeafCore/Crypto/IdentityService.swift` (new) | `ensureLocalIdentity(at root: URL = TeamKeystore.defaultRoot()) throws -> Curve25519.KeyAgreement.PrivateKey` — idempotent: читает `<root>/x25519.priv` через `TeamKeystore.readX25519Private` если exists; иначе генерирует и записывает atomically через `TeamKeystore.writeX25519Private`. Length-validated. + overload с `generate:` factory для тестов. |
| `KeyAgreement` enum-namespace | `Packages/LeafCore/Sources/LeafCore/Crypto/KeyAgreement.swift` (new) | `static func sharedSecret(privateKey:peerPublicKeyHex:) throws -> SharedSecret` (delegates to CryptoKit `privateKey.sharedSecretFromKeyAgreement(with:)`). + `static func decodePublicKey(hex:) throws -> Curve25519.KeyAgreement.PublicKey`. Pure passthrough к CryptoKit. |
| `InviteKDF` protocol + `UnimplementedInviteKDF` | `Packages/LeafCore/Sources/LeafCore/Crypto/KeyDerivation.swift` (new) | `public protocol InviteKDF: Sendable { func deriveWrapKey(sharedSecret: SharedSecret, otp: String) throws -> SymmetricKey }`. + `UnimplementedInviteKDF` placeholder throwing `.notImplemented` (mirror `UnimplementedEnvelopeCodec` 5.1.C pattern). |
| `ProdInviteKDF` impl | `Packages/LeafCorePrivate/Sources/LeafCorePrivate/Prod/Crypto/ProdInviteKDF.swift` (new, gitignored) | HKDF-SHA256(ikm=sharedSecret, salt=SHA256("\<MOAT-prefix\>" \|\| otp), info="\<MOAT\>", L=32) → SymmetricKey 256-bit. Uses CryptoKit `HKDF<SHA256>.deriveKey(...)`. OTP validation (exactly 6 ASCII digits) inside. |
| `OrgService` refactor | `Packages/LeafCore/Sources/LeafCore/Team/OrgService.swift` (edit) | Удаляет `randomX25519PrivateKey` injectable factory. Заменяет на `identity: @Sendable () throws -> Curve25519.KeyAgreement.PrivateKey` factory с default `{ try IdentityService.ensureLocalIdentity(at: keystoreRoot) }`. Inside `createPersonalOrg` step 4 заменяет `let privKey = randomX25519PrivateKey()` на `let privKey = try identity()`. **Removes** step 5a `try TeamKeystore.writeX25519Private(...)` — `IdentityService.ensureLocalIdentity` уже записывает на gen-path. |
| Tests — `IdentityServiceTests` | `Packages/LeafCore/Tests/LeafCoreTests/IdentityServiceTests.swift` (new) | 6 tests (см. §5.1) |
| Tests — `KeyAgreementTests` | `Packages/LeafCore/Tests/LeafCoreTests/KeyAgreementTests.swift` (new) | 4 tests (см. §5.2) |
| Tests — `InviteKDFTests` (public) | `Packages/LeafCore/Tests/LeafCoreTests/InviteKDFTests.swift` (new) | 2 tests (см. §5.3) |
| Tests — `ProdInviteKDFTests` (moat) | `Packages/LeafCorePrivate/Tests/LeafCorePrivateTests/ProdInviteKDFTests.swift` (new, gitignored) | 8 tests (см. §5.4) |
| Tests — `OrgServiceTests` regression edits | `Packages/LeafCore/Tests/LeafCoreTests/OrgServiceTests.swift` (edit) | Test 12 inject rename + new test 13 (см. §5.5) |

### НЕ входит (явно отложено)

- **`InviteBlob` value type / `InviteBlobCodec` protocol / `ProdInviteBlobCodec`** — **5.2.B**. KDF wires в codec тогда же.
- **`RelayClient` HTTP / `InviteService` / Generate-invite UI** — **5.2.D**.
- **`InviteAcceptService` / Accept-invite UI / Onboarding screen 6** — **5.2.E**.
- **leaf-relay endpoints** — **5.2.C** (separate repo).
- **`LeafError.inviteBlobMalformed` / `.inviteOTPInvalid` / `.relayUnreachable` etc.** — добавляются по мере появления callers (5.2.B+). 5.2.A не добавляет new LeafError cases.
- **Composition root в `Agent.swift` / `LeafApp.swift`** — substrate-only mirror 5.1.A/B/C discipline. UI wiring — 5.2.D (admin) / 5.2.E (invitee).
- **OTP→salt construction precise format** — moat внутри `ProdInviteKDF`, hidden from public surface.

---

## 3. Public API design

### `Crypto/IdentityService.swift`

```swift
import CryptoKit
import Foundation

public enum IdentityService {
    /// Idempotent. Reads existing 32B X25519 priv from <root>/x25519.priv if present;
    /// otherwise generates via Curve25519.KeyAgreement.PrivateKey() + writes atomically.
    /// Returned PrivateKey может быть использован для .publicKey.rawRepresentation OR
    /// .sharedSecretFromKeyAgreement(with:).
    public static func ensureLocalIdentity(
        at root: URL = TeamKeystore.defaultRoot()
    ) throws -> Curve25519.KeyAgreement.PrivateKey

    /// Test/dev overload — inject custom keypair generator (used only on gen-path).
    public static func ensureLocalIdentity(
        at root: URL,
        generate: @Sendable () -> Curve25519.KeyAgreement.PrivateKey
    ) throws -> Curve25519.KeyAgreement.PrivateKey
}
```

### `Crypto/KeyAgreement.swift`

```swift
import CryptoKit
import Foundation

public enum KeyAgreement {
    /// Computes ECDH shared secret. Symmetric: same value when called from either side
    /// of the keypair pair. 32 bytes via CryptoKit `sharedSecretFromKeyAgreement`.
    public static func sharedSecret(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        peerPublicKeyHex: String
    ) throws -> SharedSecret

    /// Hex decode + Curve25519 PublicKey construction. 64 lowercase-hex chars expected.
    /// Throws `LeafError.invalidPayload` если hex bad / not 64 chars / odd length /
    /// contains non-hex characters.
    public static func decodePublicKey(hex: String) throws -> Curve25519.KeyAgreement.PublicKey
}
```

### `Crypto/KeyDerivation.swift`

```swift
import CryptoKit
import Foundation

/// Derives 256-bit AES wrap key from ECDH shared secret + 6-digit OTP.
/// OTP must be exactly 6 ASCII digits 0-9. Throws `LeafError.invalidPayload` otherwise.
public protocol InviteKDF: Sendable {
    func deriveWrapKey(sharedSecret: SharedSecret, otp: String) throws -> SymmetricKey
}

public struct UnimplementedInviteKDF: InviteKDF {
    public init() {}
    public func deriveWrapKey(sharedSecret: SharedSecret, otp: String) throws -> SymmetricKey {
        throw LeafError.notImplemented
    }
}
```

### `LeafCorePrivate/Prod/Crypto/ProdInviteKDF.swift` (gitignored)

```swift
import CryptoKit
import Foundation
import LeafCore

public struct ProdInviteKDF: InviteKDF, Sendable {
    public init() {}

    public func deriveWrapKey(sharedSecret: SharedSecret, otp: String) throws -> SymmetricKey {
        // 1. Validate OTP — exactly 6 ASCII digit chars.
        // 2. otp_salt = SHA256("<moat-prefix>" || otp_utf8) — moat prefix string в .swift файле.
        // 3. wrap_key = HKDF<SHA256>.deriveKey(inputKeyMaterial: sharedSecret,
        //                                     salt: otp_salt,
        //                                     info: <moat-info-string>,
        //                                     outputByteCount: 32)
        // 4. Return wrap_key as SymmetricKey.
    }
}
```

### Algorithm — `IdentityService.ensureLocalIdentity(at root:)`

1. `try? TeamKeystore.readX25519Private(at: root)` — if returns 32B Data, construct via `Curve25519.KeyAgreement.PrivateKey(rawRepresentation:)`, return.
2. If `keyFileUnavailable` (file doesn't exist) — fall through to gen path. If `keyFileCorrupted` (size mismatch) — propagate (not silent).
3. Generate new `Curve25519.KeyAgreement.PrivateKey()` (или test-injected via overload).
4. `try TeamKeystore.writeX25519Private(privateKey.rawRepresentation, at: root)` — atomic write 0o600.
5. Return generated key.

Race note: two concurrent calls (e.g., refresh() + createPersonalOrg() on UI start) могут оба попасть в gen path. `writeAtomic` semantics — last write wins, on-disk consistent. Both calls return valid keypair, but they may differ. Mitigation: caller обязан single-thread access (UI = `@MainActor`); race в Swift sense impossible. Test 5 verifies idempotency post-first-write.

### `OrgService` refactor

```swift
public struct OrgService: Sendable {
    private let database: Database
    private let keystoreRoot: URL
    private let now: @Sendable () -> Date
    private let randomBytes: @Sendable (Int) throws -> Data
    private let randomUUID: @Sendable () -> String
    private let identity: @Sendable () throws -> Curve25519.KeyAgreement.PrivateKey  // CHANGED from randomX25519PrivateKey

    public init(
        database: Database,
        keystoreRoot: URL = TeamKeystore.defaultRoot(),
        now: @escaping @Sendable () -> Date = { Date() },
        randomBytes: @escaping @Sendable (Int) throws -> Data = OrgService.secureRandom,
        randomUUID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        identity: @escaping @Sendable () throws -> Curve25519.KeyAgreement.PrivateKey
            = OrgService.defaultIdentityFactory(keystoreRoot: keystoreRoot)  // captures keystoreRoot
    )
}
```

`createPersonalOrg(displayName:)` impl steps:
1. trim displayName + non-empty guard (unchanged).
2. `readOrg() == nil` guard (unchanged).
3. Generate IDs (unchanged).
4. **`let privKey = try identity()`** — CHANGED. Default factory delegates to `IdentityService.ensureLocalIdentity` — reads existing OR generates+writes.
5. `let teamKeyBytes = try randomBytes(TeamKeystore.teamKeyLength)` (unchanged).
6. **REMOVE** old step 5a `try TeamKeystore.writeX25519Private(...)` — IdentityService уже записал на gen-path; на read-path файл уже существует, повторная запись не нужна.
7. `try TeamKeystore.writeTeamKey(...)` (unchanged).
8. Build value types, DB writes (unchanged).
9. Return Org.

---

## 4. Design tradeoffs (зафиксировано)

- **`enum IdentityService`** mirrors `enum TeamKeystore` (5.1.D). Single-source-of-truth API per concern; default-arg `at root:` достаточно для test injection без factory ceremony. Дополнительный `generate:` overload — для тестов где нужно inject mock keypair.
- **`KeyAgreement` enum** — pure passthrough к CryptoKit; no state, no init. Sole job — hex decode + `sharedSecretFromKeyAgreement(with:)` ergonomics.
- **`InviteKDF` protocol vs concrete struct** — protocol path consistent с `EnvelopeCodec` (5.1.C). Allows substitution `UnimplementedInviteKDF` для public LeafCore tests без linking `LeafCorePrivate`. Mirror discipline; никаких exceptions для одного case.
- **Refactor OrgService — НЕ behavior change** end-user-visible: same files written, same DB rows. Но idempotent re-run (key already on disk) теперь работает корректно: previously inline `randomX25519PrivateKey()` always generated new, then `writeX25519Private` overwrote — на second `createPersonalOrg` after wipe-DB-but-not-keystore этот overwrite would lose old key. С refactor — `IdentityService.ensureLocalIdentity` reads existing first → preserves identity. Rare case (user wipes DB but не keystore вручную), but correctness improvement, и critical для invitee path который использует тот же default factory без org context.
- **Public LeafCore не linked LeafCorePrivate** — `OrgService` НЕ берёт `kdf: InviteKDF` в init (KDF используется только в 5.2.B `ProdInviteBlobCodec`, не в OrgService). 5.2.A только определяет protocol, а не wires caller.
- **HKDF info string discipline** — info string moat в `ProdInviteKDF`. Public protocol surface `deriveWrapKey(sharedSecret:otp:)` — deliberately scope-narrow (caller does not pass info choice, hard-coded inside Prod impl). Future v2 KDF (different info, different key purpose) — separate `Prod*KDF` struct, separate purpose. Single-purpose-per-impl rule.
- **OTP validation в KDF, не в caller** — `ProdInviteKDF.deriveWrapKey` throws `.invalidPayload` если OTP не 6 digits. Centralizes validation, prevents drift у callers (5.2.B InviteService, 5.2.E InviteAcceptService). Public protocol contract documents 6-digit invariant.
- **`SymmetricKey` (CryptoKit type) как return** — natively used by `AES.GCM.seal/open`. No raw `Data` exposure. Caller (5.2.B `ProdInviteBlobCodec`) consumes directly. Never persisted (wrap key derived per-invite, не stored).
- **Default `identity` factory captures `keystoreRoot`** через init parameter — `defaultIdentityFactory(keystoreRoot:)` static helper returns closure that calls `IdentityService.ensureLocalIdentity(at: keystoreRoot)`. Test injection продолжает работать через explicit `identity: { fixedKey }`.
- **5.2.A не добавляет `LeafError` cases** — `keyFileCorrupted` reused для IdentityService, `.invalidPayload` reused для KeyAgreement hex decode errors + InviteKDF OTP validation. Минимизация error surface; new cases добавятся в 5.2.B когда callers конкретизируются.

---

## 5. Test plan

### 5.1 `IdentityServiceTests.swift` (6 tests, tempDir setUp/tearDown)

Helper:
```swift
override func setUp() async throws {
    tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("leaf-identity-\(UUID().uuidString)")
}
override func tearDown() async throws {
    try? FileManager.default.removeItem(at: tempRoot)
}
```

1. **`testEnsureLocalIdentity_NoFile_GeneratesAndPersists`** — empty tempRoot → call ensureLocalIdentity → assert `<root>/x25519.priv` exists 32B 0o600, returned PrivateKey.rawRepresentation == file bytes.
2. **`testEnsureLocalIdentity_FileExists_ReadsExisting`** — pre-write 32B sentinel via `TeamKeystore.writeX25519Private` → call ensureLocalIdentity → assert returned `PrivateKey.rawRepresentation` == sentinel.
3. **`testEnsureLocalIdentity_CorruptedFile_Throws`** — pre-write 31B raw via `Data.write` (bypass keystore length validation) → call ensureLocalIdentity → throws `LeafError.keyFileCorrupted`.
4. **`testEnsureLocalIdentity_TwoConsecutiveCalls_ReturnSameKey`** — call twice in sequence → same `rawRepresentation` both times. Test-1 covers gen path; test-2 covers read path; test-4 verifies they compose: gen-then-read returns same.
5. **`testEnsureLocalIdentity_KeystoreSubdirCreatedIdempotently`** — tempRoot without `keystore/` subfolder → assert call works (creates parent subdir) + second call doesn't error.
6. **`testEnsureLocalIdentity_InjectedGenerator_UsedOnlyOnFirstCall`** — overload `generate: { fixedKey }` — first call returns fixedKey + writes; second call (also with overload) reads existing file, returns same bytes (NOT calling generate again). Verifies "lazy" semantic.

### 5.2 `KeyAgreementTests.swift` (4 tests)

1. **`testSharedSecret_RoundTrip_ECDHSymmetric`** — alice priv + bob priv (random); compute `aliceSide = KeyAgreement.sharedSecret(alicePriv, bobPubHex)`, `bobSide = KeyAgreement.sharedSecret(bobPriv, alicePubHex)`. Assert `aliceSide.withUnsafeBytes { Data($0) } == bobSide.withUnsafeBytes { Data($0) }` (32 bytes match).
2. **`testDecodePublicKey_BadHex_Throws`** — input `"ZZ".repeated(32)` (64 chars but non-hex) → throws `.invalidPayload`.
3. **`testDecodePublicKey_ShortHex_Throws`** — input 62 chars → throws `.invalidPayload`.
4. **`testDecodePublicKey_OddLength_Throws`** — input 63 chars → throws `.invalidPayload`.

### 5.3 `InviteKDFTests.swift` (2 tests, public)

1. **`testUnimplementedInviteKDF_Throws`** — `try UnimplementedInviteKDF().deriveWrapKey(...)` throws `.notImplemented`.
2. **`testInviteKDFProtocol_ExistentialAccept`** — sanity check: `let kdf: any InviteKDF = UnimplementedInviteKDF()` — compiles; runtime check just ensures no surprise.

### 5.4 `ProdInviteKDFTests.swift` (8 tests, gitignored moat)

1. **`testDeriveWrapKey_DeterministicGivenInputs`** — same priv, pub, otp → identical 32B SymmetricKey twice. Compare via `withUnsafeBytes`.
2. **`testDeriveWrapKey_DifferentOTP_DifferentKey`** — same priv, pub, otp1=`"123456"` vs otp2=`"123457"` → keys differ.
3. **`testDeriveWrapKey_DifferentSharedSecret_DifferentKey`** — different alice/bob keypairs, same OTP → keys differ.
4. **`testDeriveWrapKey_OutputIs256Bits`** — `withUnsafeBytes` size == 32.
5. **`testDeriveWrapKey_EmptyOTP_Throws`** — `""` → `.invalidPayload`.
6. **`testDeriveWrapKey_NonDigitOTP_Throws`** — `"12345a"` → `.invalidPayload`.
7. **`testDeriveWrapKey_5DigitOTP_Throws`** — `"12345"` → `.invalidPayload` (length pinned at 6).
8. **`testDeriveWrapKey_KAT_RegressionCanary`** — pre-baked sentinel: alice priv = 32B `0x01..0x01`, bob priv = 32B `0x02..0x02`, otp = `"123456"` → expected wrap key bytes hex-pinned в test source. Catches accidental info-string change / HKDF parameter drift. KAT vector computed once при write, повторно сверяется на каждом запуске.

### 5.5 `OrgServiceTests.swift` regression edits

- **Test 12 `testCreatePersonalOrg_IsInjectable`** — replace `randomX25519PrivateKey: { fixedKey }` injection с `identity: { fixedKey }`. Behavior preserved (fixedKey используется как и раньше). Also remove file-write assertion that depended on inline `writeX25519Private` call; now `IdentityService.ensureLocalIdentity` writes the same file at the same path so behavioral end-state identical, but the path of который code wrote сменился — adapt test if it checked specific call ordering.
- **New test 13 `testCreatePersonalOrg_DefaultIdentityFactory_ReadsExistingKeystoreFile`** — Setup: tempDir + tempDB; pre-write known 32B X25519 priv via `TeamKeystore.writeX25519Private`. Then construct `OrgService(database:, keystoreRoot:)` with default `identity` factory (no inject). Call `createPersonalOrg("Alice")`. Assert: `member.pubkeyHex == known_priv.publicKey.hex`. Verifies default factory hits `IdentityService.ensureLocalIdentity` → reads existing → reuses key (idempotency-after-DB-wipe scenario covered).

**Target test count:** 714 baseline → ≈735 (+21):
- 6 IdentityServiceTests
- 4 KeyAgreementTests
- 2 InviteKDFTests (public)
- 8 ProdInviteKDFTests (private moat)
- 1 new OrgServiceTests test 13
- 0 net change в test 12 (rename only, не add)

---

## 6. Build / verification

- `cd Packages/LeafCore && swift test` — all targets зелёные (LeafCoreTests, LeafCorePrivateTests, LeafMCPProtocolTests).
- `xcodebuild -scheme Leaf build` — все 5 schemes (Leaf / LeafAgent / LeafMCP / LeafCore / LeafCorePrivate) BUILD SUCCEEDED.
- `git diff feature/phase-5-1-E..feature/phase-5-2-A -- LeafAgent/Agent.swift Leaf/` пуст — composition root NOT touched (substrate-only mirror 5.1.x discipline).
- Manual smoke (post-implementation, optional): Xcode Run Debug → Organization tab → empty state → create org → quit → relaunch. Should still work end-to-end (refactor preserves user-visible behavior).
- `/pre-push-leaf` clean: HKDF info string moat'd, KAT test moat'd, no new moat-leaks в public diff.

---

## 7. Commit decomposition

Atomic, sequential. Каждый commit оставляет tree green.

| # | Commit | Файлы | Why atomic |
|---|---|---|---|
| 0 | `docs(specs): Phase 5.2 — decomposition + 5.2.A spec + plan` | `docs/superpowers/specs/2026-05-04-phase-5-2-decomposition.md` (new) + `docs/superpowers/specs/2026-05-04-phase-5-2-A-identity-kdf.md` (this) + `.claude/plans/phase-5-2-A.md` (new) | Spec lands first; downstream commits ссылаются на этот doc |
| 1 | `feat(core): Phase 5.2.A — IdentityService.ensureLocalIdentity` | `Crypto/IdentityService.swift` (new) + `IdentityServiceTests.swift` (6 tests) | Self-contained; no dependents |
| 2 | `feat(core): Phase 5.2.A — KeyAgreement ECDH wrapper + InviteKDF protocol` | `Crypto/KeyAgreement.swift` (new) + `Crypto/KeyDerivation.swift` (new) + `KeyAgreementTests.swift` (4) + `InviteKDFTests.swift` (2) | KeyAgreement + protocol both pure; no impl yet |
| 3 | `feat(private): Phase 5.2.A — ProdInviteKDF HKDF impl` (gitignored) | `LeafCorePrivate/Prod/Crypto/ProdInviteKDF.swift` (new) + `ProdInviteKDFTests.swift` (8 moat tests) | Moat impl; depends on commit 2 protocol |
| 4 | `refactor(core): Phase 5.2.A — OrgService delegates X25519 to IdentityService` | `Team/OrgService.swift` (edit) + `OrgServiceTests.swift` (edit test 12 + new test 13) | Behavior-preserving refactor; depends on commit 1 |
| 5 | (Stage 7 if needed) post-review tightening | TBD | Address `superpowers:code-reviewer` BLOCKING/N-x findings |

Push: после commit 4 — `git push -u origin feature/phase-5-2-A`. Code review запускается на pushed branch. Merge в main — отдельный шаг user'а после review pass + 5.2.B-E land целостной 5.2.A→E пятёркой (5.1 pattern).

---

## 8. Acceptance criteria

- ☐ `IdentityService.ensureLocalIdentity` idempotent (read-or-generate); 32B file 0o600.
- ☐ `KeyAgreement.sharedSecret` ECDH-symmetric (Alice ⇆ Bob).
- ☐ `KeyAgreement.decodePublicKey` rejects bad hex / wrong length.
- ☐ `InviteKDF` protocol public + `UnimplementedInviteKDF` placeholder + `ProdInviteKDF` HKDF-SHA256 impl (info string moat, output 32B).
- ☐ `ProdInviteKDF` rejects empty / non-digit / non-6-char OTP с `.invalidPayload`.
- ☐ `OrgService` `randomX25519PrivateKey` injectable заменён на `identity` factory; default delegates to `IdentityService.ensureLocalIdentity`; existing `createPersonalOrg` end-user-visible behavior preserved.
- ☐ HKDF info string + OTP→salt construction live в `LeafCorePrivate` (gitignored), не в public diff.
- ☐ `ProdInviteKDFTests.testDeriveWrapKey_KAT_RegressionCanary` — KAT vector pinned + passes (regression canary).
- ☐ ≈21 new tests; total `swift test` ≈ 735.
- ☐ Все 5 xcodebuild schemes BUILD SUCCEEDED.
- ☐ Composition root в `Agent.swift` / `Leaf/Views/` NOT touched.
- ☐ `/pre-push-leaf` clean.
- ☐ Git tree clean.

---

## 9. Open considerations (для Stage 6 review)

- **`SharedSecret` Hashable** — CryptoKit `SharedSecret` does not conform Hashable/Equatable directly (constant-time compare); test 1 sharedSecret roundtrip uses `withUnsafeBytes { Data($0) }` to compare bytes. Document this в test 1 comment.
- **`Curve25519.KeyAgreement.PublicKey` from hex** — CryptoKit init `(rawRepresentation:)` does NOT validate point-on-curve (it's accepted as-is per CryptoKit docs, all 32B-strings are valid X25519 points modulo cofactor clearing). So no extra validation needed; rely on hex-decode for first-line defense.
- **Race с `OrgReader.refresh()`** — `OrgReader` 5.1.E `refresh()` doesn't trigger ensureLocalIdentity (no need; reads org row only). 5.2.D admin generate-invite + 5.2.E accept-invite будут впервые вызывать it. Не concern для 5.2.A spec, но 5.2.D/E should ensure first-call goes through `@MainActor` boundary.
- **Test temp dir cleanup race** — IdentityServiceTests use UUID-namespaced tempDir; tearDown removes recursively. Same pattern как в 5.1.D `OrgServiceTests`. Не concern.
- **CryptoKit availability** — macOS 12+ required для `Curve25519.KeyAgreement.PrivateKey` — already met by Leaf's macOS 14+ deployment target. No conditional compilation.
- **`HKDF<SHA256>.deriveKey` vs raw `HKDF<SHA256>.extract`+`expand`** — single-step `deriveKey` API в CryptoKit since macOS 11+. Используем — proper invariant (caller не контролирует extract/expand split).
- **Test 12 OrgServiceTests adaptation** — needs careful read of existing test 12 (`testCreatePersonalOrg_IsInjectable`) to ensure rename `randomX25519PrivateKey` → `identity` doesn't break any behavioral assertion. May need to add `keystoreRoot: tempRoot` to OrgService init in that test if missing (otherwise default `identity` factory would point at user's real keystore — bad).

---

*End of spec. Tactical plan follows in `.claude/plans/phase-5-2-A.md`.*
