# Phase 5.1.C — EnvelopeCodec real impl (AES-GCM-256)

**Status:** Active (2026-05-05). Third sub-project of Phase 5.
**Owner:** Dmitrii.
**Stack:** branches off `feature/phase-5-1-B` (which holds 5.1.A + 5.1.B commits).

---

## 1. Context

Phase 5.1.C — третья sub-phase Phase 5 ("team presence relay"). Контракт уровня всей фазы — `2026-05-04-phase-5-architecture-contract.md`, §6 (envelope format) + §9 (boundary matrix).

Текущее состояние:

- Phase 5.1.A landed schema substrate (M006 `org` / M007 `team_members` / M008 `team_keys`).
- Phase 5.1.B landed value types (`Org` / `TeamMember` / `TeamKey`) + 6 GRDB helpers.
- `EnvelopeCodec` protocol + `EnvelopeHeader` struct + `UnimplementedEnvelopeCodec` placeholder уже существуют в `Packages/LeafCore/Sources/LeafCore/Crypto/Envelope.swift` (placeholder throws `LeafError.notImplemented`).
- `PresenceSnapshot` (Codable, Sendable) — `Packages/LeafCore/Sources/LeafCore/Presence/PresenceSnapshot.swift`.
- `EnvelopeCodec` нигде не используется в продакшен-коде. Первый consumer — Phase 5.4 broadcast loop.
- `LeafCorePrivate` имеет subdirs `Prod/Collectors/`, `Prod/Configs/`, `Prod/Insights/` (gitignored), composition root через `#if LEAF_PROD` в Agent.swift. `Prod/Crypto/` ещё нет.
- Test targets: `LeafCoreTests` (public) + `LeafCorePrivateTests` (moat). Baseline 674 tests after 5.1.B.

**Зачем сейчас:** Phase 5.1.D (`OrgService.createPersonalOrg` + keystore writers) генерирует первый teamKey (32 raw bytes), но без encrypt/decrypt path сам ключ — мёртвый материал. 5.1.C ставит криптослой так, чтобы 5.1.D мог выдать "вот teamKey + вот ProdEnvelopeCodec, можно шифровать", и 5.4 broadcast loop встал поверх готового codec без задержек.

**Источники правды (priority при противоречии):**

1. `2026-05-04-phase-5-architecture-contract.md` — §6 (crypto primitives + envelope format), §9 (boundary), §12 (versioning policy).
2. `leaf-docs/docs/03-architecture/presence-relay.md` — public envelope shape.
3. Существующий `Crypto/Envelope.swift` + `Presence/PresenceSnapshot.swift` — code-style template.

---

## 2. Scope

### Контрактная deviation

Контракт §9 для 5.1.C дословно: "EnvelopeCodec real impl (AES-GCM-256, X25519, HKDF) replacing UnimplementedEnvelopeCodec; helpers in LeafCorePrivate for moat-side specifics".

**Deviation:** X25519 ECDH + HKDF-SHA256 helpers перемещены в Phase 5.2 (где появляется первый real call-site — invite handshake). 5.1.C имплементирует **только AES-GCM-256** (envelope encrypt/decrypt). Причина — никакого dead кода без consumer'а; X25519/HKDF будут спроектированы вместе с invite UX в 5.2.

**Действие:** commit 1 (см. §7) патчит таблицу §9 контракта — переносит X25519/HKDF из 5.1.C-row в 5.2-row.

### Входит

| Артефакт | Файл | Заметка |
|---|---|---|
| `EnvelopeCodec` signature расширение | `Packages/LeafCore/Sources/LeafCore/Crypto/Envelope.swift` (edit) | `encode` принимает `keyID: Data`; `UnimplementedEnvelopeCodec` обновлён под новую сигнатуру |
| `EnvelopeHeader.peek(from:)` static helper | `Packages/LeafCore/Sources/LeafCore/Crypto/Envelope.swift` (edit) | read-only parse первых 17 байт (no crypto); throws на short bytes / unknown version |
| _(reuse existing `LeafError.corruptedEnvelope`)_ | `Packages/LeafCore/Sources/LeafCore/LeafError.swift` (no edit) | существующий case `corruptedEnvelope` (LeafError.swift:9) покрывает envelope parse / AES-GCM tag failures / decode JSON errors |
| `ProdEnvelopeCodec` real impl | `Packages/LeafCore/Sources/LeafCorePrivate/Prod/Crypto/ProdEnvelopeCodec.swift` (новый, **gitignored**) | CryptoKit `AES.GCM`, JSON-encoded plaintext, AAD binds version+keyID |
| Public tests | `Packages/LeafCore/Tests/LeafCoreTests/EnvelopeHeaderTests.swift` (новый) | 4 тест на `peek` + Unimplemented behavior |
| Moat tests | `Packages/LeafCore/Tests/LeafCorePrivateTests/ProdEnvelopeCodecTests.swift` (новый) | 10 тестов round-trip / structure / tamper / version / size |
| Architecture contract amendment | `docs/superpowers/specs/2026-05-04-phase-5-architecture-contract.md:230` (edit) | §9 row для 5.1.C переписан — X25519/HKDF → 5.2 |

### НЕ входит (явно отложено)

- X25519 ECDH + HKDF-SHA256 helpers — **5.2** (invite handshake first consumer).
- Composition root в Agent.swift (`#if LEAF_PROD let codec = ProdEnvelopeCodec()`) — **5.4** (broadcast loop первый caller). 5.1.C — substrate-only, mirror 5.1.A/B pattern.
- Keystore writers (raw teamKey persist в файл) — **5.1.D**. Codec работает с raw `Data` через параметр; провайдер байтов — забота 5.1.D.
- Wire format negotiation / version bump path — **v1.5+ (MLS migration)**. `version=1` единственное valid значение в MVP.
- `RelayClient` / WebSocket / Cloudflare Worker — **5.2 / 5.4**.

---

## 3. Public API design

### `Crypto/Envelope.swift` после edit'а

```swift
import Foundation

public struct EnvelopeHeader: Sendable, Hashable {
    public let version: UInt8
    public let keyID: Data    // ровно 16 bytes

    public init(version: UInt8, keyID: Data) {
        self.version = version
        self.keyID = keyID
    }

    public static let currentVersion: UInt8 = 1

    /// Read-only parse первых 17 байт envelope (1B version + 16B keyID).
    /// No crypto — caller использует возвращённый `keyID`, чтобы найти
    /// соответствующий teamKey в keystore (history rotation), потом вызывает
    /// `EnvelopeCodec.decode(bytes, teamKey)`.
    ///
    /// Throws `LeafError.corruptedEnvelope` если:
    /// - `bytes.count < 17`
    /// - `version != currentVersion`
    public static func peek(from bytes: Data) throws -> EnvelopeHeader
}

public protocol EnvelopeCodec: Sendable {
    /// Сериализует snapshot (JSON), шифрует под `teamKey` (AES-GCM-256),
    /// embedd'ит `keyID` в envelope header.
    /// - Parameters:
    ///   - snapshot: Codable payload.
    ///   - keyID: ровно 16 bytes (UUID team_keys.id raw bytes).
    ///   - teamKey: ровно 32 bytes raw AES-256 key.
    /// - Returns: bytes envelope `[ver:1B|keyID:16B|nonce:12B|ct|tag:16B]`.
    /// - Throws: `LeafError.corruptedEnvelope` на bad input sizes.
    func encode(_ snapshot: PresenceSnapshot,
                keyID: Data,
                teamKey: Data) throws -> Data

    /// Расшифровывает envelope под `teamKey`. Caller обязан ДО вызова
    /// peek'нуть header (`EnvelopeHeader.peek(from:)`) и найти
    /// teamKey по `header.keyID` в keystore.
    /// - Throws: `LeafError.corruptedEnvelope` на short bytes / unknown version /
    ///           AES-GCM tag mismatch / JSON decode failure.
    func decode(_ bytes: Data, teamKey: Data) throws -> PresenceSnapshot
}

public struct UnimplementedEnvelopeCodec: EnvelopeCodec {
    public init() {}
    public func encode(_ snapshot: PresenceSnapshot,
                       keyID: Data,
                       teamKey: Data) throws -> Data {
        throw LeafError.notImplemented
    }
    public func decode(_ bytes: Data, teamKey: Data) throws -> PresenceSnapshot {
        throw LeafError.notImplemented
    }
}
```

### `LeafError.corruptedEnvelope`

**Reuse existing** — `LeafError.swift:9` уже содержит `corruptedEnvelope` case (без associated value). Discovered в exploration; новый case не нужен. Diagnostic detail логируется отдельно через каллер; envelope errors в protocol throws bare `.corruptedEnvelope`.

---

## 4. Moat impl design (LeafCorePrivate)

### `Prod/Crypto/ProdEnvelopeCodec.swift` (gitignored)

```swift
import CryptoKit
import Foundation
import LeafCore

public struct ProdEnvelopeCodec: EnvelopeCodec {
    public init() {}

    public func encode(_ snapshot: PresenceSnapshot,
                       keyID: Data,
                       teamKey: Data) throws -> Data {
        // 1. Validate input sizes (throws .corruptedEnvelope)
        // 2. JSON-encode snapshot (JSONEncoder default — sortedKeys для
        //    determinism в тестах nonce uniqueness — НЕТ, snapshot уже
        //    Codable struct с фиксированным порядком полей)
        // 3. SymmetricKey(data: teamKey)
        // 4. AES.GCM.Nonce() (random 12B per call — never reuse)
        // 5. Сборка AAD = serialised header bytes [ver:1B | keyID:16B]
        // 6. AES.GCM.seal(jsonBytes, using: key, nonce: nonce, authenticating: aad)
        // 7. Сборка envelope: header || nonce || ciphertext || tag
    }

    public func decode(_ bytes: Data, teamKey: Data) throws -> PresenceSnapshot {
        // 1. EnvelopeHeader.peek(from: bytes) — ловит short / version
        // 2. Validate teamKey size, total bytes >= 45
        // 3. Reconstruct AAD из первых 17 bytes
        // 4. Slice nonce / ciphertext / tag
        // 5. AES.GCM.SealedBox(nonce:, ciphertext:, tag:)
        // 6. AES.GCM.open(box, using: key, authenticating: aad) → jsonBytes
        // 7. JSONDecoder().decode(PresenceSnapshot.self, from: jsonBytes)
    }
}
```

### Что moat (живёт ТОЛЬКО в этом файле)

- Точная композиция AAD (порядок байтов в concat, padding если есть).
- Точные slice-границы при unpack envelope (если когда-нибудь добавим extra fields).
- `JSONEncoder` configuration (sortedKeys / dateEncodingStrategy / etc).
- Любые safety checks beyond `.corruptedEnvelope` mapping.

### Что НЕ moat (в public layer / whitepaper)

- Envelope shape `[ver|keyID|nonce|ct|tag]` — whitepaper.
- AES-GCM-256 / 12B nonce / 16B tag — whitepaper.
- JSON для plaintext serialization — derivable из `PresenceSnapshot: Codable`.

---

## 5. Test plan

### `LeafCoreTests/EnvelopeHeaderTests.swift` (4 теста)

1. `testPeek_RoundTrip` — собрать вручную bytes [`0x01`, …16B keyID…, …trash…] → `peek` возвращает version=1, keyID=ожидаемые 16B.
2. `testPeek_RejectShortBytes` — bytes.count < 17 → throws `.corruptedEnvelope`.
3. `testPeek_RejectUnknownVersion` — version=2 / version=0 → throws `.corruptedEnvelope`.
4. `testUnimplementedCodec_StillThrowsAfterSignatureChange` — `UnimplementedEnvelopeCodec().encode(...)` + `.decode(...)` оба throws `.notImplemented` (защита что placeholder не сломался).

### `LeafCorePrivateTests/ProdEnvelopeCodecTests.swift` (10 тестов)

Helper `makeKey()` → 32 random bytes; `makeKeyID()` → 16 random bytes; `makeSnapshot()` → fixed PresenceSnapshot.

1. `testEncodeDecode_RoundTrip` — encode → decode возвращает snapshot, equal по всем полям.
2. `testEncode_EnvelopeStructure` — encode'нутый stream: count == 45 + jsonSize; first byte == 1; bytes[1..17] == keyID.
3. `testEncode_KeyIDRoundTripsViaPeek` — `EnvelopeHeader.peek(from: encoded)` → header.keyID == input keyID.
4. `testEncode_NonceUniqueness` — encode тот же snapshot 2 раза одним teamKey/keyID → bytes[17..29] (nonce slice) различны.
5. `testEncode_DistinctEncodings` — два encode под одним teamKey/keyID → entire byte streams различны (nonce ensures это).
6. `testDecode_RejectsTamperedCiphertext` — encode → flip 1 byte в ciphertext slice (bytes[29..-16]) → decode throws.
7. `testDecode_RejectsTamperedTag` — flip 1 byte в last 16B → decode throws.
8. `testDecode_RejectsTamperedHeaderKeyID` — flip 1 byte в bytes[1..17] (AAD bound) → decode throws.
9. `testDecode_RejectsWrongTeamKey` — encode с keyA, decode с keyB → throws.
10. `testDecode_RejectsTruncated` — encode → drop last 5 bytes → throws `.corruptedEnvelope` либо tag failure.

Optional bonus, если time permits:
- `testDecode_RejectsUnknownVersion` — flip byte[0] = 2 → throws `.corruptedEnvelope`.
- `testEncode_DifferentKeyIDsAffectCiphertext` — same snapshot, same teamKey, different keyID → entire ciphertext различен (за счёт AAD).

**Target test count:** baseline 674 → ~688 (+4 public + 10 moat).

---

## 6. Build / verification

- `cd Packages/LeafCore && swift test` — все три targets зелёные (LeafCoreTests, LeafCorePrivateTests, LeafMCPProtocolTests).
- `xcodebuild -scheme Leaf build` — все 5 схем (Leaf / LeafAgent / LeafMCP / LeafCore / LeafCorePrivate) BUILD SUCCEEDED.
- `git status` clean (никаких ProdCrypto файлов случайно не tracked — gitignored).
- `/pre-push-leaf` clean (no AAD bytes / nonce ordering / info strings в public).

---

## 7. Commit decomposition

Atomic, sequential, one logical change per commit. Каждый commit оставляет tree green (`swift test` passes).

| # | Commit | Файлы | Why atomic |
|---|---|---|---|
| 1 | `docs(specs): Phase 5.1.C — contract §9 amendment (X25519/HKDF → 5.2)` | `docs/superpowers/specs/2026-05-04-phase-5-architecture-contract.md` (edit §9 row) + this spec file | Contract patch landed first; следующие commits ссылаются на amended row |
| 2 | `feat(core): Phase 5.1.C — EnvelopeHeader.peek static helper` | `Crypto/Envelope.swift` (extend EnvelopeHeader) + `EnvelopeHeaderTests.swift` (4 tests) | Public surface для peek (reuses existing `LeafError.corruptedEnvelope`); tests первыми (TDD) |
| 3 | `feat(core): Phase 5.1.C — EnvelopeCodec signature accepts keyID` | `Crypto/Envelope.swift` (protocol + Unimplemented update) | Sig change осторожно — Unimplemented и ProdEnvelopeCodec compile вместе |
| 4 | `feat(core): Phase 5.1.C — ProdEnvelopeCodec AES-GCM real impl` | `LeafCorePrivate/Prod/Crypto/ProdEnvelopeCodec.swift` (new, gitignored) + `ProdEnvelopeCodecTests.swift` (10 tests) | Moat lands; все тесты round-trip / tamper / size зелёные |
| 5 | `docs(shared): Phase 5.1.C landed — current-state update` | `.claude/shared/current-state.md` | Final landing entry; mirror 5.1.B `ac0a89c` |

Push: после commit 5 — `git push -u origin feature/phase-5-1-C`. Merge в main — отдельный шаг user'а после code review.

---

## 8. Acceptance criteria

- ☐ Contract §9 для 5.1.C amended (X25519/HKDF → 5.2).
- ☐ `EnvelopeHeader.peek(from:)` parses 17-byte prefix, throws на bad version / short bytes.
- ☐ `EnvelopeCodec.encode` теперь принимает `keyID: Data` параметр; signature change применён к Unimplemented и Prod вместе.
- ☐ `LeafError.corruptedEnvelope` reused (no new case added).
- ☐ `ProdEnvelopeCodec` живёт в `LeafCorePrivate/Prod/Crypto/`, gitignored, использует CryptoKit `AES.GCM`, AAD binds header.
- ☐ 14 новых тестов (4 public + 10 moat), `swift test` зелёный, total ≈688.
- ☐ Все 5 xcodebuild schemes BUILD SUCCEEDED.
- ☐ Composition root в Agent.swift НЕ изменён (substrate-only).
- ☐ `/pre-push-leaf` clean.
- ☐ Git tree clean, ProdCrypto не tracked.

---

## 9. Open considerations (для review)

- **Equatable PresenceSnapshot:** round-trip test compares snapshot до/после. `PresenceSnapshot` сейчас `Codable + Sendable` без Equatable. Решение: либо добавить `Equatable` conformance (тривиально — все поля Equatable), либо сравнивать через re-encode JSON. Plan: добавить Equatable conformance в commit 4 (one-line, тестируемое поведение).
- **Endianness of UInt8 (version):** не имеет значения — single byte. Future ver=2 bump — single byte too.
- **PresenceSnapshot.timestamp Date encoding:** `JSONEncoder` default — `.deferredToDate` (Double seconds since 2001). Approx ms precision. ОК для round-trip (Equatable будет по same Double bit pattern). Если нужна wire-level stability → switch на `.millisecondsSince1970` в moat impl. Decision deferred to commit 4.

---

*End of spec. Plan file follows in `.claude/plans/phase-5-1-C.md`.*
