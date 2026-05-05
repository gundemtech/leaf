# Phase 5.2.B — `InviteBlob` + `ProdInviteBlobCodec` (AES-GCM-256)

**Status:** Active (2026-05-05). Second sub-phase of Phase 5.2 ("relay invite endpoints + invite UX + ECDH handshake").
**Owner:** Dmitrii.
**Stack:** branches off `feature/phase-5-2-A` (which holds 5.2.A commits `2862914..705e3d0`).

---

## 1. Context

Phase 5.2.A landed 5 commits — three primitives под invite handshake:

- `IdentityService.ensureLocalIdentity(at:)` — idempotent X25519 priv on disk (32B file).
- `KeyAgreement.sharedSecret(privateKey:peerPublicKeyHex:)` — ECDH wrapper, lenient hex decode.
- `InviteKDF.deriveWrapKey(sharedSecret:otp:)` protocol + `ProdInviteKDF` HKDF-SHA256 impl (moat info string + OTP→salt construction).
- `OrgService.createPersonalOrg` рефакторнут делегировать identity в `IdentityService` (no behaviour change).

Output цепочки: `KeyAgreement.sharedSecret` → `InviteKDF.deriveWrapKey` → 32-byte AES-256 `SymmetricKey` готов для wrap/unwrap.

**Зачем 5.2.B сейчас:** 5.2.D (`InviteService` admin orchestrator) и 5.2.E (`InviteAcceptService` invitee orchestrator) будут передавать `team_key` по байтам через relay в encrypted opaque blob (контракт §5: "relay sees only opaque encrypted blobs"). 5.2.B ставит криптослой именно для wrap'а: `[ver:1B | admin_pubkey:32B | nonce:12B | ciphertext | tag:16B]` AES-GCM-256 envelope с AAD-bound header + JSON plaintext shape. Без 5.2.B 5.2.D не сможет даже собрать body для `POST /v1/invite`.

**Источники правды (priority при противоречии):**

1. `2026-05-04-phase-5-architecture-contract.md` — §6 (crypto primitives + envelope format generic), §10 (failure modes).
2. `2026-05-04-phase-5-2-decomposition.md` — §3 (sub-phase scope locked), §4.1 (file layout — **path table неточный**, см. §2 ниже), §4.3 (wire layout + AAD + plaintext JSON shape), §4.6 (LeafError additions).
3. `leaf-docs/docs/03-architecture/presence-relay.md` — public-truth invite handshake invariants (24h token, 6-digit OTP, X25519 ECDH, HKDF-SHA256, OOB transmission).
4. Existing `Packages/LeafCore/Sources/LeafCore/Crypto/Envelope.swift` + `LeafCorePrivate/Prod/Crypto/ProdEnvelopeCodec.swift` — code-style template (5.1.C precedent).

---

## 2. Decomposition spec path-table discrepancy

`2026-05-04-phase-5-2-decomposition.md` §4.1 указывает moat-пути как `Packages/LeafCorePrivate/Sources/LeafCorePrivate/Prod/Crypto/...`. **Фактический layout** (verified against 5.1.C precedent + filesystem):

```
Packages/LeafCore/Sources/LeafCore/...           ← public target sources
Packages/LeafCore/Sources/LeafCorePrivate/...    ← moat target sources (gitignored)
Packages/LeafCore/Tests/LeafCoreTests/...        ← public tests
Packages/LeafCore/Tests/LeafCorePrivateTests/... ← moat tests (gitignored)
Packages/LeafCore/Package.swift                  ← single SPM manifest
```

5.2.B uses actual paths. Final commit (#6 опциональный) патчит decomposition spec §4.1 row для будущих фаз (5.2.C-E читают тот же документ).

---

## 3. Scope

### Входит

| Артефакт | Файл | Заметка |
|---|---|---|
| `InvitePlaintext` value type (Codable + snake_case JSON keys) | `Packages/LeafCore/Sources/LeafCore/Team/InvitePlaintext.swift` (новый) | 7 полей JSON wire shape per decomposition §4.3 |
| `InviteBlob` value type (Data wrapper) + `InviteBlobHeader` + `peek(from:)` | `Packages/LeafCore/Sources/LeafCore/Team/InviteBlob.swift` (новый) | `currentVersion=2`, `prefixSize=33` (1B+32B), `aadPrefixSize=45`, `fixedOverhead=61` |
| `InviteBlobCodec` protocol + `UnimplementedInviteBlobCodec` placeholder | `Packages/LeafCore/Sources/LeafCore/Crypto/InviteBlobCodec.swift` (новый) | `encode(plaintext, adminPubkey, wrapKey)` + `decode(blob, wrapKey)` |
| `LeafError` +2 cases | `Packages/LeafCore/Sources/LeafCore/LeafError.swift` (edit) | `inviteBlobMalformed` + `inviteOTPInvalid` per decomposition §4.6 |
| `ProdInviteBlobCodec` real impl | `Packages/LeafCore/Sources/LeafCorePrivate/Prod/Crypto/ProdInviteBlobCodec.swift` (новый, **gitignored**) | CryptoKit `AES.GCM`, JSON `.sortedKeys`, AAD = full 45B prefix (header + nonce) |
| Public tests | `Tests/LeafCoreTests/InvitePlaintextTests.swift` (4) + `InviteBlobHeaderTests.swift` (4) + `InviteBlobCodecTests.swift` (2) | 10 public tests |
| Moat tests | `Tests/LeafCorePrivateTests/ProdInviteBlobCodecTests.swift` | 13 moat tests round-trip / structure / tamper / size validation / truncation |

### НЕ входит (явно отложено)

- **Composition root** в `LeafAgent/Agent.swift` (`#if LEAF_PROD let inviteCodec = ProdInviteBlobCodec()`) — **5.2.D** (`InviteService` admin orchestrator — first real consumer). 5.2.B substrate-only, mirror 5.1.C pattern.
- **`inviteOTPInvalid` actually thrown by code** — case добавлен, но не заwiren. 5.2.D `InviteService` orchestrator catches `.invalidPayload` from `deriveWrapKey` и rethrows как `.inviteOTPInvalid` для clearer state-machine surface. 5.2.B adds case "in advance" чтобы 5.2.D commits не трогали LeafError.
- **`RelayClient` wire encoding** (base64url JSON body) — 5.2.D (`RelayClient` HTTP layer; `InviteBlob` value type stays domain-pure raw `Data`).
- **MessagePack plaintext** — 5.2.B uses JSON; MessagePack reserved per decomposition §4.3 для post-MVP.
- **Deterministic-nonce KAT regression on blob bytes** — random-nonce by design; KAT canary lives at `ProdInviteKDF` layer (5.2.A).
- **Whitepaper sync** — `presence-relay.md` уже описывает invite flow абстрактно. Public truth update — Phase 5.2 end-of-track при 5.2.E ship.

---

## 4. Public surface (LeafCore)

### 4.1 `InvitePlaintext`

```swift
public struct InvitePlaintext: Sendable, Hashable, Codable {
    public let teamKeyBase64: String      // 44 chars (32B base64-encoded raw AES-256 team_key)
    public let teamKeyID: String          // UUID lowercase (FK to team_keys.id)
    public let orgID: String              // UUID lowercase (FK to org.id)
    public let orgName: String            // utf8 (admin's display name for org)
    public let adminMemberID: String      // UUID lowercase (FK to team_members.id)
    public let adminDisplayName: String   // utf8
    public let issuedAtMs: Int64          // ms epoch (audit)

    public init(teamKeyBase64: String, teamKeyID: String, orgID: String,
                orgName: String, adminMemberID: String, adminDisplayName: String,
                issuedAtMs: Int64)

    private enum CodingKeys: String, CodingKey {
        case teamKeyBase64 = "team_key"
        case teamKeyID = "team_key_id"
        case orgID = "org_id"
        case orgName = "org_name"
        case adminMemberID = "admin_member_id"
        case adminDisplayName = "admin_display_name"
        case issuedAtMs = "issued_at_ms"
    }
}
```

**Decision:** `teamKeyBase64: String` (not `teamKey: Data`). Reason — `Data + Codable` JSONEncoder emits base64 anyway; explicit string keeps base64 boundary auditable + lets unit tests assert exact JSON keys without bytes-decoding overhead. Caller (5.2.D admin generate) base64-encodes raw 32B before constructing `InvitePlaintext`; caller (5.2.E invitee accept) base64-decodes after.

### 4.2 `InviteBlob` + `InviteBlobHeader`

```swift
/// Bytes layout: [ ver:1B | admin_pubkey:32B | nonce:12B | ciphertext | tag:16B ]
/// Public envelope shape — whitepaper presence-relay.md §invite handshake.
/// AAD construction / JSON plaintext shape / nonce gen — moat в LeafCorePrivate/Prod/Crypto/.
public struct InviteBlob: Sendable, Hashable {
    public let bytes: Data
    public init(bytes: Data) { self.bytes = bytes }
}

public struct InviteBlobHeader: Sendable, Hashable {
    public let version: UInt8
    public let adminPubkey: Data        // 32 bytes — admin's X25519 public

    public init(version: UInt8, adminPubkey: Data)

    public static let currentVersion: UInt8 = 2     // 0x02 — invite blob (envelope = 0x01)
    public static let prefixSize: Int = 33          // 1B ver + 32B pub
    public static let nonceSize: Int = 12
    public static let tagSize: Int = 16
    public static let aadPrefixSize: Int = 45       // 1B ver + 32B pub + 12B nonce
    public static let fixedOverhead: Int = 61       // prefix + nonce + tag

    /// Read-only parse первых 33 байт (1B version + 32B admin pubkey). No crypto.
    /// Caller использует возвращённый adminPubkey, чтобы выполнить
    /// `KeyAgreement.sharedSecret(invitee_priv, adminPubkey.hex)` →
    /// `InviteKDF.deriveWrapKey(sharedSecret, otp)` → `wrapKey`,
    /// затем `InviteBlobCodec.decode(blob, wrapKey: wrapKey)`.
    /// Throws `LeafError.inviteBlobMalformed` на bytes < 33 / version != currentVersion.
    public static func peek(from blob: InviteBlob) throws -> InviteBlobHeader
}
```

`InviteBlob` — wrapper struct (не `typealias Data`). Domain typing prevents confusion с raw `Data` через `RelayClient` API; Hashable/Sendable for free; не Codable (wire base64url encoding — 5.2.D `RelayClient` concern, не value type).

### 4.3 `InviteBlobCodec`

```swift
public protocol InviteBlobCodec: Sendable {
    /// Сериализует plaintext (JSON), шифрует AES-GCM-256 под wrapKey,
    /// embedd'ит admin_pubkey в header.
    /// - Parameters:
    ///   - plaintext: invite payload to encrypt.
    ///   - adminPubkey: ровно 32 bytes (admin's X25519 public).
    ///   - wrapKey: 32-byte AES key из InviteKDF.deriveWrapKey.
    /// - Returns: InviteBlob `[ver:1B|adminPubkey:32B|nonce:12B|ct|tag:16B]`.
    /// - Throws: `LeafError.inviteBlobMalformed` на bad input sizes / encoding failure.
    func encode(_ plaintext: InvitePlaintext,
                adminPubkey: Data,
                wrapKey: SymmetricKey) throws -> InviteBlob

    /// Расшифровывает blob под wrapKey. Caller обязан peek'нуть header первым,
    /// извлечь adminPubkey, выполнить ECDH+KDF, передать сюда wrapKey.
    /// - Throws: `LeafError.inviteBlobMalformed` на short bytes / version mismatch /
    ///           AES-GCM tag fail (включая wrong wrapKey / wrong OTP) / JSON decode failure.
    func decode(_ blob: InviteBlob, wrapKey: SymmetricKey) throws -> InvitePlaintext
}

public struct UnimplementedInviteBlobCodec: InviteBlobCodec {
    public init() {}
    public func encode(_ plaintext: InvitePlaintext,
                       adminPubkey: Data,
                       wrapKey: SymmetricKey) throws -> InviteBlob {
        throw LeafError.notImplemented
    }
    public func decode(_ blob: InviteBlob, wrapKey: SymmetricKey) throws -> InvitePlaintext {
        throw LeafError.notImplemented
    }
}
```

**Why decode collapses "wrong wrapKey" + "wrong OTP" + "wrong invitee priv" в один `inviteBlobMalformed`?** AES-GCM tag fail upstream неотличим — это feature, не bug. Per decomposition §8 risks "Invitee enters wrong invitee pubkey" + §4.6 single error case. UX слой (5.2.E `InviteAcceptReader`) classifies user-facing message ("OTP doesn't match — ask admin to send again" vs "blob corrupt") via state-machine context, не via error variants.

### 4.4 `LeafError` additions

```swift
public enum LeafError: Error, Sendable {
    // existing 9 cases unchanged
    case inviteBlobMalformed       // 5.2.B — codec failures (size / version / tag / JSON)
    case inviteOTPInvalid          // 5.2.B — OTP not 6 ASCII digits (orchestrator-only; unused в 5.2.B)
}
```

`inviteOTPInvalid` сейчас никем не throws — case добавлен заранее ради 5.2.D `InviteService` (orchestrator catches `.invalidPayload` от `deriveWrapKey` и rethrows как `.inviteOTPInvalid`). 5.2.B keeps single LeafError-touching commit; 5.2.D consumer wires.

---

## 5. Moat surface (LeafCorePrivate, gitignored)

### 5.1 `ProdInviteBlobCodec.swift`

`Packages/LeafCore/Sources/LeafCorePrivate/Prod/Crypto/ProdInviteBlobCodec.swift` — gitignored per `.gitignore` rule:

```
Packages/LeafCore/Sources/LeafCorePrivate/**/*.swift
!Packages/LeafCore/Sources/LeafCorePrivate/Placeholder.swift
```

Mirrors `ProdEnvelopeCodec` (5.1.C) с этими отличиями:

| Aspect | ProdEnvelopeCodec | ProdInviteBlobCodec |
|---|---|---|
| Version byte | `0x01` (`EnvelopeHeader.currentVersion`) | `0x02` (`InviteBlobHeader.currentVersion`) |
| Header content | 1B ver + 16B keyID = 17B | 1B ver + 32B adminPubkey = 33B |
| AAD content | 17B header (ver + keyID, **excluding nonce**) | 45B header + nonce (ver + adminPubkey + nonce, **including nonce** per spec §4.3) |
| Plaintext type | `PresenceSnapshot` | `InvitePlaintext` |
| Plaintext encoding | `JSONEncoder()` defaults | `JSONEncoder()` with `outputFormatting = .sortedKeys` (deterministic byte-equality across encodes when input fields equal — auditable) |
| Fixed overhead | 45B | 61B |

**Why AAD includes nonce in invite blob but not envelope?** Decomposition spec §4.3 explicit. Practically AES-GCM binds nonce internally to ciphertext; explicit inclusion в AAD belt-and-braces (tampering nonce slice fails decode either way — двойная защита, не вред). Contract spec literal — следуем literally чтобы invite blob (`ver=0x02`) семантически отличался от envelope (`ver=0x01`); also "header = всё до ciphertext" в invite (asymmetric nonce role: envelope's keyID — index-only, invite's adminPubkey + nonce identify channel together).

**Constants:**

```swift
private static let wrapKeySize = 32
private static let pubkeySize = 32
private static let nonceSize = InviteBlobHeader.nonceSize     // 12
private static let tagSize = InviteBlobHeader.tagSize         // 16
private static var headerPrefixSize: Int { InviteBlobHeader.prefixSize }  // 33
private static var aadPrefixSize: Int { InviteBlobHeader.aadPrefixSize }   // 45
private static var fixedOverhead: Int { InviteBlobHeader.fixedOverhead }   // 61
```

**Encode flow:**

1. Validate `adminPubkey.count == 32` (else `.inviteBlobMalformed`).
2. JSON-encode `plaintext` via `JSONEncoder()` `.sortedKeys`; throw `.inviteBlobMalformed` on encode failure.
3. Build `header33 = [ver(1) | adminPubkey(32)]`.
4. Generate `nonce = AES.GCM.Nonce()` (random 12B).
5. Build `aad45 = header33 || nonceData(12)`.
6. `sealed = AES.GCM.seal(plaintext, using: wrapKey, nonce: nonce, authenticating: aad45)`.
7. Assemble blob = `[header33 | nonce(12) | sealed.ciphertext | sealed.tag(16)]`.
8. Return `InviteBlob(bytes: blob)`.

**Decode flow:**

1. `header = try InviteBlobHeader.peek(from: blob)` — validates `bytes >= 33` + `version == 2`.
2. `bytes >= 61` else `.inviteBlobMalformed`.
3. Slice: `header33 = bytes[0..<33]`, `nonceData = bytes[33..<45]`, `tag = bytes[count-16..<count]`, `ct = bytes[45..<count-16]`.
4. `aad45 = header33 || nonceData`.
5. `nonce = try AES.GCM.Nonce(data: nonceData)`; `sealed = AES.GCM.SealedBox(nonce:, ciphertext:, tag:)`; `plaintext = try AES.GCM.open(sealed, using: wrapKey, authenticating: aad45)`.
6. JSON-decode `InvitePlaintext.self` from plaintext bytes.
7. Any failure → `.inviteBlobMalformed` (single collapsed error per §4.3).

---

## 6. Tests

### 6.1 `InvitePlaintextTests` (public, 4)

1. `testCodable_RoundTripPreservesAllFields` — encode → decode → equality.
2. `testCodable_JSONKeysAreSnakeCase` — encode, JSONSerialization parse, assert keys `team_key`, `team_key_id`, `org_id`, `org_name`, `admin_member_id`, `admin_display_name`, `issued_at_ms` present.
3. `testCodable_RejectsMissingField` — decode partial JSON (e.g., missing `org_id`) throws.
4. `testHashable_DistinctValuesNotEqual` — sanity (two plaintexts с разным `orgID` не equal).

### 6.2 `InviteBlobHeaderTests` (public, 4 — mirror `EnvelopeHeaderTests`)

1. `testPeek_RoundTripsAdminPubkey` — synthetic blob `[0x02 | 32B pubkey | 28B random tail]`, `peek` returns matching pubkey.
2. `testPeek_RejectShortBytes` — `Data(repeating: 0, count: 32)` → `.inviteBlobMalformed`.
3. `testPeek_RejectUnknownVersion` — `Data([0x01]) + Data(count: 64)` → throws.
4. `testConstants_MatchSpec` — assert `currentVersion == 2`, `prefixSize == 33`, `aadPrefixSize == 45`, `nonceSize == 12`, `tagSize == 16`, `fixedOverhead == 61`. Pinning constants regression-tests spec contract.

### 6.3 `InviteBlobCodecTests` (public, 2 — stub discipline)

1. `testUnimplementedCodec_EncodeThrowsNotImplemented`.
2. `testUnimplementedCodec_DecodeThrowsNotImplemented`.

### 6.4 `ProdInviteBlobCodecTests` (moat, 13 — mirror `ProdEnvelopeCodecTests`)

1. `testEncodeDecode_RoundTrip` — full payload round-trip, equality on `InvitePlaintext`.
2. `testEncode_BlobStructure` — `bytes.count >= 61`, byte 0 = `0x02`, bytes [1..33] = embedded adminPubkey.
3. `testEncode_AdminPubkeyRoundTripsViaPeek`.
4. `testEncode_NonceUniqueness` — two encodes of same plaintext+key produce distinct nonces.
5. `testEncode_DistinctEncodings` — full blobs differ.
6. `testDecode_RejectsTamperedCiphertext` — flip mid-ciphertext byte.
7. `testDecode_RejectsTamperedTag` — flip last byte.
8. `testDecode_RejectsTamperedHeaderVersion` — flip byte 0.
9. `testDecode_RejectsTamperedAdminPubkey` — flip byte 5 (within 1..33 pubkey slice — AAD bound).
10. `testDecode_RejectsTamperedNonce` — flip byte 35 (within nonce slice — AAD bound).
11. `testDecode_RejectsWrongWrapKey` — encode under key A, decode under key B → throw.
12. `testEncode_RejectsBadAdminPubkeySize` — sizes [0, 1, 16, 31, 33, 64] all throw.
13. `testDecode_RejectsTruncated` — drop last 5 bytes (eats into tag).

---

## 7. Plan (commits — atomic, sequential per `superpowers:test-driven-development`)

| # | Commit message | Scope |
|---|---|---|
| 1 | `docs(specs): Phase 5.2.B — invite blob + codec spec` | this file |
| 2 | `feat(core): Phase 5.2.B — InvitePlaintext value type + LeafError cases` | InvitePlaintext.swift + 2 LeafError cases + 4 tests |
| 3 | `feat(core): Phase 5.2.B — InviteBlob + InviteBlobHeader.peek` | InviteBlob.swift + 4 tests |
| 4 | `feat(core): Phase 5.2.B — InviteBlobCodec protocol + Unimplemented stub` | InviteBlobCodec.swift + 2 tests |
| 5 | `feat(private): Phase 5.2.B — ProdInviteBlobCodec AES-GCM impl (gitignored)` | ProdInviteBlobCodec.swift + 13 moat tests |
| 6 (opt) | `chore(specs): Phase 5.2.B — patch decomposition path table` | decomposition spec §4.1 path correction |

Each commit: write tests → run → see fail → implement → run → see pass → commit (per `superpowers:test-driven-development`). Scheme matrix runs only at Stage 7 verification (commit-level cost not justified for substrate-only changes; first time integration risk surfaces — full matrix).

---

## 8. Verification gate (Stage 7)

```bash
cd /Users/ddemidov/Desktop/Leaf/leaf
( cd Packages/LeafCore && swift test ) 2>&1 | tail -20
# Expect "Executed X tests" с +23 от 5.2.A baseline (LeafCore +10, LeafCorePrivate +13)
# Expect "0 failures"

for s in Leaf LeafAgent LeafMCP LeafCore LeafCorePrivate; do
  xcodebuild -scheme "$s" -configuration Debug build -quiet 2>&1 | tail -3
done
# Expect 5× "BUILD SUCCEEDED"

git status --porcelain | grep -E "LeafCorePrivate.*Prod.*\.swift" || echo "OK: no moat files tracked"

git log --oneline feature/phase-5-2-A..HEAD
# Expect 5-6 commits, atomic, prefixes feat(core)/feat(private)/chore(specs)
```

UI smoke — N/A (no UI surface). Whitepaper sync — N/A (deferred to 5.2.E landing).

---

## 9. Critical files referenced

| Path | Why |
|---|---|
| `Packages/LeafCore/Sources/LeafCore/Crypto/Envelope.swift` | Template for `InviteBlobCodec` protocol surface |
| `Packages/LeafCore/Sources/LeafCorePrivate/Prod/Crypto/ProdEnvelopeCodec.swift` | Template AES-GCM impl + AAD construction + slice arithmetic |
| `Packages/LeafCore/Tests/LeafCoreTests/EnvelopeHeaderTests.swift` | Template for header-peek tests |
| `Packages/LeafCore/Tests/LeafCorePrivateTests/ProdEnvelopeCodecTests.swift` | Template for moat AES-GCM test matrix |
| `Packages/LeafCore/Sources/LeafCore/Crypto/KeyDerivation.swift` | `InviteKDF` protocol — wrapKey output consumed here |
| `Packages/LeafCore/Sources/LeafCore/Team/{Org,TeamMember,TeamKey}.swift` | Style for Sendable/Hashable value types |
| `Packages/LeafCore/Sources/LeafCore/LeafError.swift` | Append 2 cases at end |
| `Packages/LeafCore/Package.swift` | Verify no manifest edit needed (auto-include) |
| `.gitignore` | Confirm rule covers new moat file |
| `docs/superpowers/specs/2026-05-04-phase-5-2-decomposition.md` §3, §4.1, §4.3, §4.6 | Contract |

---

## 10. Risks + mitigations

| Risk | Mitigation |
|---|---|
| AAD-with-nonce diverges from `ProdEnvelopeCodec` discipline → confusion later | Inline comment in `ProdInviteBlobCodec` references decomposition §4.3 + explains belt-and-braces reasoning |
| `InvitePlaintext.teamKeyBase64: String` leaks encoding into domain type | Acceptable — explicit base64 boundary auditable; alternative (`Data` + `.base64DecodingStrategy`) hidden behavior |
| 5.2.D consumer might want `InviteBlob.bytes` exposed as base64url for HTTP body (currently raw `Data`) | 5.2.D `RelayClient` does base64url encode/decode itself; `InviteBlob` value type stays domain-pure |
| Future MessagePack swap breaks JSON-key tests | Tests pin keys explicitly per spec §4.3 — additive cost (not blocker) при swap |
| Decomposition §4.1 path table wrong | §2 documents discrepancy; commit 6 patches non-blocking |
| `.sortedKeys` JSON encoding adds ~µs cost vs default | Wrap path called once per invite (rare), no measurable impact |

---

*End of spec. On approval → execute commits 1→5 sequentially per TDD discipline. Stage 6 review (`superpowers:code-reviewer`) after commit 5; Stage 7 verification before pushing branch.*
