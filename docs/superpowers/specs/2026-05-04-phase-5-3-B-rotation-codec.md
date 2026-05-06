# Phase 5.3.B — `RotationBlobCodec` + `RotationKDF` (codec substrate)

**Status:** Active (2026-05-06). Second sub-phase of Phase 5.3 ("member removal + team key rotation").
**Owner:** Dmitrii.
**Stack base:** `feature/phase-5-3-A` (5.3.A landed @ 816 SPM tests).
**Branch:** `feature/phase-5-3-B`.

---

## 1. Context

Phase 5.3.A landed 4 commits — три DB lifecycle helpers (`markTeamMemberRemoved`, `deprecateTeamKey`, `readTeamKey(byID:)`). Substrate под team key rotation готов на DB-уровне.

Phase 5.3.B — **substrate sub-phase**: wire format для wrapped peer-key drop. Domain-separated от invite codec через distinct version byte (`0x03`), distinct HKDF info string, distinct AAD layout. Без 5.3.B Phase 5.3.D `KeyRotationService` не сможет собрать body для `POST /v1/key-rotation` в 5.3.C.

**Зачем сейчас:** 5.3.D (admin orchestrator) и 5.3.E (peer fetch loop) обоим нужно encode/decode rotation blob:
- 5.3.D: per remaining peer ECDH(admin_priv, peer.pub) → HKDF → AES-GCM-256 wrap нового teamKey + per removed peer AES-GCM-256 wrap tombstone-sentinel под prior teamKey.
- 5.3.E: peer fetch'ит pending rotations → ECDH(self_priv, admin.pub) → HKDF → unwrap → install via `insertTeamKey` + `deprecateTeamKey(old)`.

Как и 5.1.C / 5.2.B — protocol surface в `LeafCore` + Unimplemented placeholder; реальная impl в `LeafCorePrivate` (gitignored moat); composition root в Agent.swift НЕ трогается, первый caller = 5.3.D.

**Источники правды (priority при противоречии):**

1. `2026-05-04-phase-5-architecture-contract.md` §6 (crypto primitives) + §10 (failure modes) + §12 ("MUST reject unknown versions").
2. `.claude/plans/phase-5-3-overview.md` §5.3.B — locked scope, AD #1 (separate codec), AD #5 (no OTP), AD #6 (tombstone semantics).
3. `LeafCore/Crypto/InviteBlobCodec.swift` + `LeafCorePrivate/Prod/Crypto/ProdInviteBlobCodec.swift` — code-style template.
4. `LeafCore/Crypto/Envelope.swift` + `ProdEnvelopeCodec.swift` — header peek + version reservation template.

---

## 2. Scope

### Входит

| Артефакт | Файл | Заметка |
|---|---|---|
| `RotationKind` enum + `RotationPlaintext` Codable | `Packages/LeafCore/Sources/LeafCore/Team/RotationPlaintext.swift` (новый) | snake_case wire keys; kind discriminator `.rotation` / `.tombstone` |
| `RotationBlob` Data wrapper + `RotationBlobHeader` + `peek` | `Packages/LeafCore/Sources/LeafCore/Team/RotationBlob.swift` (новый) | `currentVersion=3`; `prefixSize=65`; `aadPrefixSize=77`; `fixedOverhead=93` |
| `RotationBlobCodec` protocol + `UnimplementedRotationBlobCodec` | `Packages/LeafCore/Sources/LeafCore/Crypto/RotationBlobCodec.swift` (новый) | `encode(plaintext, recipientPubkey, wrapKey)` + `decode(blob, wrapKey)` |
| `RotationKDF` protocol + `UnimplementedRotationKDF` | `Packages/LeafCore/Sources/LeafCore/Crypto/RotationKDF.swift` (новый) | `deriveWrapKey(sharedSecret, newKeyID)` — без OTP |
| `LeafError` +1 case | `LeafError.swift` (edit) | `rotationBlobMalformed` |
| `ProdRotationBlobCodec` real impl | `Packages/LeafCore/Sources/LeafCorePrivate/Prod/Crypto/ProdRotationBlobCodec.swift` (новый, **gitignored**) | CryptoKit `AES.GCM`, JSON `.sortedKeys`, AAD = full 77B prefix |
| `ProdRotationKDF` real impl | `Packages/LeafCore/Sources/LeafCorePrivate/Prod/Crypto/ProdRotationKDF.swift` (новый, **gitignored**) | HKDF-SHA256, info `"leaf.rotation.wrapkey.v1"`, salt = `newKeyID` 16B |
| Public tests | `Tests/LeafCoreTests/{RotationPlaintextTests, RotationBlobHeaderTests, RotationBlobCodecTests, RotationKDFTests}.swift` | 11-13 public tests |
| Moat tests | `Tests/LeafCorePrivateTests/{ProdRotationBlobCodecTests, ProdRotationKDFTests}.swift` (gitignored) | 15-18 moat tests |

### НЕ входит (явно отложено)

- **Composition root** в `LeafAgent/Agent.swift` (`#if LEAF_PROD let rotationCodec = ProdRotationBlobCodec()`) — **5.3.D** (`KeyRotationService` first real consumer). 5.3.B substrate-only, mirror 5.1.C / 5.2.B.
- `RelayClient.postRotationBlob` / `fetchPendingRotations` / `ackRotation` → 5.3.C.
- `KeyRotationService` / `MemberRemovalService` / `RotationOutbox` → 5.3.D.
- `RotationFetchService` / `RotationFetchScheduler` peer-side → 5.3.E.
- UI: Remove member sheet / RemovedFromTeamBanner → 5.3.E.
- `TeamKeystore` extension to multi-key history slot — 5.3.D when first consumer needs new key persisted.

---

## 3. Wire format

### 3.1 Bytes layout (`ver = 0x03`)

```
[ver:1B | prior_keyID:16B | new_keyID:16B | recipient_pubkey:32B | nonce:12B | ciphertext | tag:16B]
```

| Slice | Bytes | Source |
|---|---|---|
| `ver` | 1B | constant `0x03` (envelope=`0x01`, invite=`0x02`) |
| `prior_keyID` | 16B | UUID raw bytes — `team_keys.id` of currently-active key being deprecated |
| `new_keyID` | 16B | UUID raw bytes — `team_keys.id` of new active key (== `prior_keyID` for tombstone) |
| `recipient_pubkey` | 32B | recipient's X25519 public key |
| `nonce` | 12B | random per encode (never reuse with same wrapKey) |
| `ciphertext` | var | AES-GCM-256 encrypted JSON `RotationPlaintext` |
| `tag` | 16B | AES-GCM auth tag |

`prefixSize = 65` (1 + 16 + 16 + 32). `aadPrefixSize = 77` (prefix + nonce). `fixedOverhead = 93` (prefix + nonce + tag, excludes plaintext bytes).

### 3.2 AAD construction

`AAD = ver || prior_keyID || new_keyID || recipient_pubkey || nonce` = full 77B prefix.

Mirror `ProdInviteBlobCodec` belt-and-braces style. AES-GCM internally binds nonce to ciphertext; explicit AAD inclusion **also** binds (version, both keyIDs, recipientPubkey) to the auth tag — tampering anywhere in the prefix invalidates decryption.

### 3.3 Plaintext (`RotationPlaintext`) — JSON wire shape

```json
{
  "kind": "rotation",
  "new_team_key": "<base64 44 chars>",
  "new_key_id": "<UUID lowercase>",
  "prior_key_id": "<UUID lowercase>",
  "generated_at_ms": 1730000000000,
  "removed_member_id": null
}
```

For tombstone:
```json
{
  "kind": "tombstone",
  "new_team_key": "",
  "new_key_id": "<UUID lowercase>",        // == prior_key_id
  "prior_key_id": "<UUID lowercase>",
  "generated_at_ms": 1730000000000,
  "removed_member_id": "<UUID lowercase>"  // member.id of removed peer
}
```

JSON encoder uses `.sortedKeys` for deterministic byte-equality across encodes.

### 3.4 Cross-field invariants (post-decrypt validation in `ProdRotationBlobCodec.decode`)

- `kind == .rotation` → `newTeamKeyBase64.count == 44` (44 chars decoded == 32B AES-256) **AND** `newKeyID != priorKeyID` **AND** `removedMemberID == nil`.
- `kind == .tombstone` → `newTeamKeyBase64.isEmpty` **AND** `newKeyID == priorKeyID` **AND** `removedMemberID != nil`.

Violation throws `LeafError.rotationBlobMalformed`. Validation is **post-decrypt** so an unauthenticated attacker cannot trigger different code paths via crafted plaintext — they'd fail GCM tag first.

---

## 4. Public surface (LeafCore)

### 4.1 `RotationKind` + `RotationPlaintext`

```swift
public enum RotationKind: String, Sendable, Hashable, Codable {
    case rotation
    case tombstone
}

public struct RotationPlaintext: Sendable, Hashable, Codable {
    public let kind: RotationKind
    public let newTeamKeyBase64: String      // 44 chars for .rotation; "" for .tombstone
    public let newKeyID: String              // UUID lowercase
    public let priorKeyID: String            // UUID lowercase
    public let generatedAtMs: Int64
    public let removedMemberID: String?      // nil for .rotation; member.id for .tombstone

    public init(kind: RotationKind,
                newTeamKeyBase64: String,
                newKeyID: String,
                priorKeyID: String,
                generatedAtMs: Int64,
                removedMemberID: String?) { ... }

    private enum CodingKeys: String, CodingKey {
        case kind
        case newTeamKeyBase64 = "new_team_key"
        case newKeyID = "new_key_id"
        case priorKeyID = "prior_key_id"
        case generatedAtMs = "generated_at_ms"
        case removedMemberID = "removed_member_id"
    }
}
```

### 4.2 `RotationBlob` + `RotationBlobHeader`

```swift
public struct RotationBlob: Sendable, Hashable {
    public let bytes: Data
    public init(bytes: Data) { self.bytes = bytes }
}

public struct RotationBlobHeader: Sendable, Hashable {
    public let version: UInt8
    public let priorKeyID: Data    // 16B
    public let newKeyID: Data      // 16B
    public let recipientPubkey: Data  // 32B

    public static let currentVersion: UInt8 = 3
    public static let priorKeyIDSize: Int = 16
    public static let newKeyIDSize: Int = 16
    public static let recipientPubkeySize: Int = 32
    public static let prefixSize: Int = 65   // 1+16+16+32
    public static let nonceSize: Int = 12
    public static let tagSize: Int = 16
    public static let aadPrefixSize: Int = 77   // 65+12
    public static let fixedOverhead: Int = 93   // 65+12+16

    /// Read-only parse first 65 bytes. No crypto.
    /// Throws `LeafError.rotationBlobMalformed` if bytes < 65 or version != 3.
    public static func peek(from blob: RotationBlob) throws -> RotationBlobHeader
}
```

`peek` rejects:
- bytes < 65 → `.rotationBlobMalformed`
- version != 3 (включая 0x01 envelope, 0x02 invite, 0xFF, и любой `> 3` per contract §12) → `.rotationBlobMalformed`

### 4.3 `RotationBlobCodec`

```swift
public protocol RotationBlobCodec: Sendable {
    /// JSON-encode plaintext, AES-GCM-256 seal под wrapKey, build envelope.
    /// `priorKeyID`, `newKeyID` приходят из `plaintext` и embedд'ятся в header.
    /// - Throws: `LeafError.rotationBlobMalformed` на bad input sizes / encoding failure.
    func encode(_ plaintext: RotationPlaintext,
                recipientPubkey: Data,
                wrapKey: SymmetricKey) throws -> RotationBlob

    /// Caller обязан peek'нуть header первым (`RotationBlobHeader.peek`)
    /// чтобы извлечь priorKeyID/newKeyID/recipientPubkey + derive wrapKey
    /// (либо ECDH+HKDF для .rotation, либо raw prior teamKey для .tombstone).
    /// - Throws: `LeafError.rotationBlobMalformed` на short bytes / version mismatch /
    ///           AES-GCM tag fail (включая wrong wrapKey) / JSON decode failure /
    ///           cross-field invariant violation.
    func decode(_ blob: RotationBlob, wrapKey: SymmetricKey) throws -> RotationPlaintext
}

public struct UnimplementedRotationBlobCodec: RotationBlobCodec {
    public init() {}
    // both methods throw LeafError.notImplemented
}
```

### 4.4 `RotationKDF`

```swift
public protocol RotationKDF: Sendable {
    /// HKDF-SHA256 over (sharedSecret, salt = newKeyID, info = "...rotation.wrapkey.v1").
    /// `newKeyID` MUST be exactly 16B raw UUID; throws `LeafError.invalidPayload` otherwise.
    func deriveWrapKey(sharedSecret: SharedSecret, newKeyID: Data) throws -> SymmetricKey
}

public struct UnimplementedRotationKDF: RotationKDF {
    public init() {}
    public func deriveWrapKey(sharedSecret: SharedSecret, newKeyID: Data) throws -> SymmetricKey {
        throw LeafError.notImplemented
    }
}
```

**No OTP** (overview AD #5): peer pubkey trust-validated через invite handshake (5.2). ECDH(admin_priv, peer.pub) authenticated by `team_members` row membership. `newKeyID` 16B serves as HKDF salt — fresh wrapKey per rotation even if same admin↔peer pair re-derives same `SharedSecret`.

### 4.5 `LeafError` addition

```swift
case rotationBlobMalformed   // analog of inviteBlobMalformed; no analog of inviteOTPInvalid (no OTP)
```

Surfaced from `ProdRotationBlobCodec.encode/decode` + `RotationBlobHeader.peek` errors.

---

## 5. Moat (LeafCorePrivate)

### 5.1 `ProdRotationBlobCodec`

CryptoKit `AES.GCM.seal/open` mirror'ит `ProdInviteBlobCodec` структуру. Differences:
- `version = 0x03` (vs invite 0x02).
- Header = 65B (priorKeyID + newKeyID + recipientPubkey, vs invite's 33B = adminPubkey only).
- AAD = full 77B prefix (vs invite's 45B). Same belt-and-braces style.
- Encode validates `recipientPubkey.count == 32`; decode validates length + cross-field invariants.

### 5.2 `ProdRotationKDF`

Moat constants:
- `hkdfInfo = Data("leaf.rotation.wrapkey.v1".utf8)` — distinct from invite `"leaf.invite.wrapkey.v1"` for cryptographic domain separation.
- `wrapKeyLength = 32` (256-bit AES key).
- Salt = `newKeyID` raw 16B (no SHA256 wrap — UUID is already random).
- Validates `newKeyID.count == 16` else throws `LeafError.invalidPayload`.

```swift
public func deriveWrapKey(sharedSecret: SharedSecret, newKeyID: Data) throws -> SymmetricKey {
    guard newKeyID.count == Self.newKeyIDSize else { throw LeafError.invalidPayload }
    return sharedSecret.hkdfDerivedSymmetricKey(
        using: SHA256.self,
        salt: newKeyID,
        sharedInfo: Self.hkdfInfo,
        outputByteCount: Self.wrapKeyLength
    )
}
```

---

## 6. Test plan

**Public tests** (target ≈ 11-13 cases):

`RotationPlaintextTests.swift`:
1. Codable round-trip rotation
2. Codable round-trip tombstone
3. Snake_case wire keys assertion (decode JSON literal)
4. Distinct rotation vs tombstone equal-comparable

`RotationBlobHeaderTests.swift`:
1. Peek round-trip — all three byte slices recovered
2. Short-bytes (< 65) → `.rotationBlobMalformed`
3. Version != 3 → `.rotationBlobMalformed` (cases: 0x01 envelope, 0x02 invite, 0xFF arbitrary)
4. Header constants assertion (prefixSize/aadPrefixSize/fixedOverhead correct)

`RotationBlobCodecTests.swift`:
1. UnimplementedRotationBlobCodec.encode → `.notImplemented`
2. UnimplementedRotationBlobCodec.decode → `.notImplemented`

`RotationKDFTests.swift`:
1. UnimplementedRotationKDF.deriveWrapKey → `.notImplemented`
2. Sanity: protocol existential conforms to Sendable

**Moat tests** (target ≈ 15-18 cases, gitignored):

`ProdRotationBlobCodecTests.swift`:
1. Round-trip rotation (encode → decode → equal plaintext)
2. Round-trip tombstone
3. Blob structure (ver byte + priorKeyID + newKeyID + recipientPubkey at correct offsets via index arithmetic)
4. KeyIDs round-trip via `peek` independently of decode
5. Nonce uniqueness across two encodes (same key + plaintext)
6. Distinct full-blob encodings (encode×2 не equal)
7. Tampered ciphertext → `.rotationBlobMalformed`
8. Tampered tag → `.rotationBlobMalformed`
9. Tampered version (0x03 → 0x02) → `.rotationBlobMalformed` (peek catches before AES open)
10. Tampered priorKeyID byte → `.rotationBlobMalformed` (AAD-bound)
11. Tampered newKeyID byte → `.rotationBlobMalformed` (AAD-bound)
12. Tampered recipientPubkey byte → `.rotationBlobMalformed` (AAD-bound)
13. Tampered nonce → `.rotationBlobMalformed`
14. Wrong wrapKey → `.rotationBlobMalformed`
15. Truncated blob (eats into tag) → `.rotationBlobMalformed`
16. Cross-field: rotation kind with empty newTeamKey on decode → `.rotationBlobMalformed`
17. Cross-field: tombstone kind with non-empty newTeamKey on decode → `.rotationBlobMalformed`
18. Bad recipientPubkey size on encode → `.rotationBlobMalformed` (loop sizes 0/1/16/31/33/64)

`ProdRotationKDFTests.swift`:
1. KAT-style determinism — same SharedSecret + same newKeyID → bit-identical wrapKey bytes
2. Different newKeyID → different wrapKey
3. Bad newKeyID size (0 / 1 / 8 / 15 / 17 / 32) → `.invalidPayload`
4. Domain isolation: same SharedSecret + same 16B input value → `ProdInviteKDF` (with synthetic OTP) and `ProdRotationKDF` derive **distinct** keys (single-line SymmetricKey-equality assertion demonstrating info-string domain separation)

**Total Δ:** ~26-31 new test cases (public 11-13 + moat 15-18).

Baseline 5.3.A: 816 SPM tests. Target end-of-5.3.B: ~840-845.

---

## 7. Verification (Stage 7 — phase ship gate)

```bash
swift test --package-path Packages/LeafCore                                # all pass; Δ matches plan
xcodebuild build -scheme Leaf      -configuration Debug                    # BUILD SUCCEEDED
xcodebuild build -scheme LeafAgent -configuration Debug                    # BUILD SUCCEEDED
xcodebuild build -scheme LeafMCP   -configuration Debug                    # BUILD SUCCEEDED
xcodebuild build -scheme LeafCore  -configuration Debug                    # BUILD SUCCEEDED
xcodebuild build -scheme LeafCorePrivate -configuration Debug              # BUILD SUCCEEDED
```

No manual smoke (substrate-only — first end-to-end smoke at 5.3.E ship-gate two-Mac test).

---

## 8. Pre-push checklist (`gundemtech/leaf` is public)

`/pre-push-leaf` before `git push origin feature/phase-5-3-B`:
- ❌ NO public diff exposes `hkdfInfo` literal value, salt construction, AAD byte composition — all moat → `LeafCorePrivate/Prod/Crypto/` (gitignored).
- ✅ Public surface = protocol shape, version byte (`0x03` reserved value, public envelope shape already in whitepaper presence-relay.md description).
- ✅ Public test assertions cover *shape* not *secret values*.

---

## 9. Whitepaper sync

NONE during 5.3.B — implementation moat (codec internals + KDF info-string) doesn't surface to public docs. Changelog entry deferred to Phase 5.3 ship'у в alpha.X (5.3.E ship-gate), pattern consistent с 5.1.A-E + 5.2.A-E.

---

## 10. Commit decomposition (target ~8 commits)

1. `docs(specs): Phase 5.3.B — RotationBlobCodec spec` — this file.
2. `feat(core): Phase 5.3.B — LeafError.rotationBlobMalformed` + 1 sanity test.
3. `feat(core): Phase 5.3.B — RotationPlaintext + RotationKind` + 4 tests.
4. `feat(core): Phase 5.3.B — RotationBlob + RotationBlobHeader.peek` + 4 tests.
5. `feat(core): Phase 5.3.B — RotationBlobCodec protocol + Unimplemented` + 2 tests.
6. `feat(core): Phase 5.3.B — RotationKDF protocol + Unimplemented` + 2 tests.
7. `feat(core/private): Phase 5.3.B — ProdRotationBlobCodec` + 15-18 moat tests (gitignored).
8. `feat(core/private): Phase 5.3.B — ProdRotationKDF` + 4 moat tests (gitignored).
9. (optional) `docs(shared): Phase 5.3.B landed — current-state update` — final landing commit per Stage 8.

---

## 11. Forward dependencies

- Phase 5.3.D `KeyRotationService` consumes `ProdRotationBlobCodec` + `ProdRotationKDF` via composition root in Agent.swift (`#if LEAF_PROD`).
- Phase 5.3.E `RotationFetchService` consumes both for peer-side decode.
- No further Phase 5.x consumer; Phase 5.4 (presence broadcast) uses **`ProdEnvelopeCodec`** (already shipped 5.1.C), not rotation codec.
- Phase 5.5 (Onboarding final integration) — no codec dependency.

---

## 12. Risks / open questions

1. **Tombstone forgeability** — wrapKey for tombstone = prior teamKey shared by all team members. Any current member could forge a "you were removed" blob targeting another peer. Acceptable per overview AD #6 (trust boundary = team membership; non-admin members already have full read access to encrypted history). Not mitigated in 5.3; future hardening could sign tombstone with admin's X25519 private key (Ed25519 detached signature) but adds wire complexity not justified yet.
2. **`recipientPubkey` for tombstone** — set to removed peer's X25519 pubkey for routing audit, but wrapKey is shared, so semantically the field is more "addressee" than "key derivation input". Decoder doesn't enforce match between `recipientPubkey` in header and any local identity — only relay routing uses it (5.3.C `?peer_pubkey=hex` URL param).
3. **Plaintext byte size** — JSON `RotationPlaintext` ~200B + 93B fixed overhead → ~293B per blob × N peers × per-rotation. For team N=50, N-1=49 wraps × 293B = ~14KB total post per rotation. Trivially under any KV size budget.
4. **HKDF salt = `newKeyID` UUID** — UUIDs not strictly cryptographically random (depends on generator), but `Foundation.UUID()` on Apple platforms uses `arc4random` ⇒ CSPRNG-quality. Acceptable.
