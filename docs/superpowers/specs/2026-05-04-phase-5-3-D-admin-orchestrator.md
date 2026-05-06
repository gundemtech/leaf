# Phase 5.3.D — `KeyRotationService` admin orchestrator + `RotationOutbox` journal

**Status:** Active (2026-05-06). Fourth sub-phase of Phase 5.3 ("member removal + team key rotation").
**Owner:** Dmitrii.
**Stack base:** `feature/phase-5-3-C` (5.3.C landed @ 880 SPM tests).
**Branch:** `feature/phase-5-3-D`.

---

## 1. Context

Phase 5.3 substrate готов на трёх уровнях: 5.3.A — DB lifecycle mutators (`markTeamMemberRemoved` / `deprecateTeamKey` / `readTeamKey(byID:)`); 5.3.B — codec substrate (`RotationBlobCodec` + `RotationKDF` + `Prod*` impls — moat); 5.3.C — wire surface (`RelayClient.{postRotationBlob, fetchPendingRotations, ackRotation}` + leaf-relay `/v1/key-rotation/*` endpoints, KV `KEY_ROTATIONS` namespace, list-then-ACK semantic, composite-key idempotency on `(peer, new_key_id)`).

Phase 5.3.D — **first real consumer**: admin orchestrator который композирует все три substrate'а в atomic flow. Когда админ кикает member'а из команды, нужно (a) сгенерировать новый teamKey, (b) deprecate'нуть старый, (c) пометить removed peer, (d) для каждого remaining peer завернуть новый ключ через ECDH+HKDF под их pubkey + для removed peer завернуть `.tombstone` под старый teamKey, (e) положить wrapped blobs на relay, (f) пережить crash mid-iteration через write-ahead journal.

Без 5.3.D админ не может произвести rotation — все примитивы есть, но нет orchestrator'а.

**Зачем сейчас:** 5.3.E (peer fetch loop + UI Remove-menu + RemovedFromTeamBanner + two-Mac smoke ship-gate) требует admin'а способного rotate'нуть на N peers — иначе peer fetch loop'у нечего fetch'ить. 5.3.D = верхняя половина admin↔peer handshake'а.

**Источники правды (priority при противоречии):**

1. `2026-05-04-phase-5-architecture-contract.md` §7 (Key lifecycle — рост teamKey rotation triggered ONLY by member removal в MVP) + §10 (Failure modes — relay outage / stale rotation TTL / mid-install crash) + §12 (forever-retained team_keys).
2. `2026-05-04-phase-5-3-A-db-mutators.md` §3-§4 (helpers + atomic semantics).
3. `2026-05-04-phase-5-3-B-rotation-codec.md` §3-§4 (wire format) + §10 risks (tombstone forgeability, recipientPubkey routing role).
4. `2026-05-04-phase-5-3-C-relay-rotation.md` §6 (composite-key idempotency guarantee — critical for resume) + §10 (forward-compat hand-off для 5.3.D).
5. `Packages/LeafCore/Sources/LeafCore/Invite/InviteService.swift` + `InviteAcceptService.swift` — orchestrator code-style template (factory injection, preflight, atomic compose-then-write).
6. `Database.writeEventsOffsetAndPresence` (lines 249-276) — multi-step atomic-tx precedent through single `pool.write { db in ... }` block.

---

## 2. Scope

### Входит

#### `gundemtech/leaf` (Swift, SPM + Agent target)

| Артефакт | Файл | Заметка |
|---|---|---|
| `M009_RotationOutbox` migration | `Packages/LeafCore/Sources/LeafCore/DB/Migrations/M009_RotationOutbox.swift` (новый) | Composite PK `(peer_pubkey_hex, new_key_id)`; partial index `rotation_outbox_unposted` |
| `Schema.RotationOutbox` namespace | `Packages/LeafCore/Sources/LeafCore/DB/Schema.swift` (edit) | Table + column + index name constants |
| `RotationOutboxRow` value type | `Packages/LeafCore/Sources/LeafCore/Team/RotationOutboxRow.swift` (новый) | Sendable, Hashable; mirror `IntegrationRecord` style |
| `RotationOutcome` value type | `Packages/LeafCore/Sources/LeafCore/Team/RotationOutcome.swift` (новый) | Return type для `removeMember` + `resumePendingPosts` |
| `Database.commitRotation(...)` | `Packages/LeafCore/Sources/LeafCore/DB/Database.swift` (edit, `// MARK: - Rotation outbox (Phase 5.3.D)`) | Single atomic `pool.write` — INSERT new team_key + UPDATE prior deprecated + optional UPDATE removed member + INSERT N outbox rows |
| `Database.markRotationOutboxPosted(...)` | same | UPDATE `posted_at_ms` on composite key; idempotent silent no-op if missing/already-posted |
| `Database.readUnpostedRotationOutboxRows()` | same | SELECT * FROM rotation_outbox WHERE posted_at_ms IS NULL ORDER BY created_at_ms |
| `LeafError.cannotRemoveSelfFromTeam` | `Packages/LeafCore/Sources/LeafCore/LeafError.swift` (edit) | New case для preflight surface |
| `KeyRotationService` | `Packages/LeafCore/Sources/LeafCore/Team/KeyRotationService.swift` (новый) | Public struct — `removeMember(memberID:) -> RotationOutcome` + `resumePendingPosts() -> RotationOutcome` |
| Public tests | `Tests/LeafCoreTests/{RotationOutboxRow, RotationOutcome, DatabaseRotationOutbox, KeyRotationService}Tests.swift` (новые) | ~25-30 cases SPM |
| Moat E2E test | `Tests/LeafCorePrivateTests/RotationHandshakeIntegrationTests.swift` (gitignored) | 2-3 cases, full ProdRotationKDF + ProdRotationBlobCodec round-trip + URLProtocol stub for relay |
| Composition root | `LeafAgent/Agent.swift` (edit, после InviteService block) | `#if LEAF_PROD` rotation codec/KDF + `KeyRotationService` instantiation + `Task.detached { resumePendingPosts() }` |

### НЕ входит (явно отложено)

- **Peer fetch loop** `RotationFetchService` + `RotationFetchScheduler` → 5.3.E.
- **UI**: `TeamView` per-row "Remove…" context menu / `RemoveMemberSheet` confirmation / `RemovedFromTeamBanner` org-wipe banner / `OrgReader.removedFromOrg` flag → 5.3.E.
- **Two-Mac smoke ship-gate** — manual за юзером после 5.3.E ship.
- **Proactive rotation API** (`rotate()` без removal) — internal `performRotation(removingMember:)` принимает optional, готов для v1.1 расширения, но public surface MVP — только `removeMember(memberID:)`.
- **Sole-admin invariant** на UI level — service throws `cannotRemoveSelfFromTeam` если `memberID == selfMemberID`. Multi-admin scenario (admin1 removing admin2) — service позволяет; UI-level confirmation ("are you sure you want to demote/remove another admin") — concern 5.3.E.
- **Per-member rotation rate limiting** — relay имеет TTL + composite-key dedup. Admin может вызвать removeMember multiple раз подряд для разных members — каждый вызов = отдельный rotation event (новый newKeyID). Acceptable per AD.
- **Privacy Dashboard surfacing** для resumePending failures — logs go to stderr/agent log; surface в UI = future (post-MVP).
- **Test coverage для existing helpers** (`insertTeamKey`, `deprecateTeamKey`, `markTeamMemberRemoved`) — уже covered Phase 5.1.B + 5.3.A.

---

## 3. Schema (M009)

### 3.1 Table

```swift
// Packages/LeafCore/Sources/LeafCore/DB/Migrations/M009_RotationOutbox.swift

extension DatabaseMigrator {
    mutating func registerMigration009RotationOutbox() {
        registerMigration("009_rotation_outbox") { db in
            try db.create(table: Schema.RotationOutbox.tableName, ifNotExists: true) { t in
                t.column(Schema.RotationOutbox.peerPubkeyHex, .text).notNull()
                t.column(Schema.RotationOutbox.newKeyID, .text).notNull()
                t.column(Schema.RotationOutbox.priorKeyID, .text).notNull()
                t.column(Schema.RotationOutbox.kind, .text).notNull()
                    .check { $0 == "rotation" || $0 == "tombstone" }
                t.column(Schema.RotationOutbox.peerMemberID, .text).notNull()
                t.column(Schema.RotationOutbox.blob, .blob).notNull()
                t.column(Schema.RotationOutbox.expiresAtMs, .integer).notNull()
                t.column(Schema.RotationOutbox.createdAtMs, .integer).notNull()
                t.column(Schema.RotationOutbox.postedAtMs, .integer)
                t.primaryKey([
                    Schema.RotationOutbox.peerPubkeyHex,
                    Schema.RotationOutbox.newKeyID,
                ])
            }
            try db.create(
                index: Schema.RotationOutbox.indexUnposted,
                on: Schema.RotationOutbox.tableName,
                columns: [Schema.RotationOutbox.createdAtMs],
                condition: Column(Schema.RotationOutbox.postedAtMs) == nil
            )
        }
    }
}
```

### 3.2 Schema namespace addition

```swift
// Packages/LeafCore/Sources/LeafCore/DB/Schema.swift
public enum Schema {
    // ... existing ...
    
    public enum RotationOutbox {
        public static let tableName = "rotation_outbox"
        public static let peerPubkeyHex = "peer_pubkey_hex"
        public static let newKeyID = "new_key_id"
        public static let priorKeyID = "prior_key_id"
        public static let kind = "kind"
        public static let peerMemberID = "peer_member_id"
        public static let blob = "blob"
        public static let expiresAtMs = "expires_at_ms"
        public static let createdAtMs = "created_at_ms"
        public static let postedAtMs = "posted_at_ms"
        public static let indexUnposted = "rotation_outbox_unposted"
    }
}
```

### 3.3 Migration registration

`Database.swift` — registerMigration call site (mirror M001..M008 pattern).

---

## 4. Public API surface

### 4.1 `RotationOutboxRow`

```swift
public struct RotationOutboxRow: Sendable, Hashable {
    public let peerPubkeyHex: String      // 64 hex chars (X25519 public)
    public let newKeyID: String           // UUID lowercase
    public let priorKeyID: String         // UUID lowercase
    public let kind: RotationKind         // .rotation | .tombstone
    public let peerMemberID: String       // UUID lowercase
    public let blob: Data                 // raw RotationBlob bytes (encrypted)
    public let expiresAtMs: Int64
    public let createdAtMs: Int64
    public let postedAtMs: Int64?         // nil = unposted

    public init(...)
}
```

`RotationKind` reused from 5.3.B (`Packages/LeafCore/Sources/LeafCore/Team/RotationPlaintext.swift`).

### 4.2 `RotationOutcome`

```swift
public struct RotationOutcome: Sendable, Hashable {
    public let newKeyID: String           // newly-generated rotation ID; "" for resumePending all-empty case
    public let priorKeyID: String         // deprecated rotation ID; "" for resumePending all-empty case
    public let postedCount: Int           // POST 201 successful
    public let pendingCount: Int          // POST failed; will retry on next resumePending
    public let totalCount: Int            // postedCount + pendingCount

    public init(...)
}
```

Использование UI 5.3.E: `try await keyRotationService.removeMember(memberID: x)` → display toast «Rotation done; N peers will sync when online» если `pendingCount > 0`.

### 4.3 `Database.commitRotation`

```swift
public func commitRotation(
    newTeamKey: TeamKey,
    priorTeamKeyID: String,
    deprecatedAt: Date,
    removedMemberID: String?,
    removedAt: Date?,
    outboxRows: [RotationOutboxRow]
) throws
```

Single `pool.write { db in ... }` body executes:

1. Mode-guard: `guard mode == .writer else { throw .databaseUnavailable }`.
2. Pre-validation: если `removedMemberID != nil` ⇒ `removedAt != nil`; иначе both nil. Throw `.invalidPayload` on mismatch.
3. INSERT новой team_keys row (mirror `insertTeamKey` SQL inline).
4. UPDATE prior team_keys row's `deprecated_at_ms = ?` WHERE `id = priorTeamKeyID AND deprecated_at_ms IS NULL`. Read `db.changesCount`:
   - 1 → success.
   - 0 → SELECT row by id для disambiguation: missing → throw `.invalidPayload`; already-deprecated → throw `.invalidPayload` (rotation orchestrator caller bug — admin shouldn't initiate rotation от стейта где prior-key already deprecated).
5. Если `removedMemberID != nil`: UPDATE team_members `removed_at_ms = ? WHERE id = ? AND removed_at_ms IS NULL`. `changesCount` 0 → SELECT for disambiguation; missing → throw `.invalidPayload`; already-removed → throw `.invalidPayload` (caller bug — admin shouldn't initiate rotation для already-removed member).
6. Для каждого row в `outboxRows`: INSERT INTO rotation_outbox (composite PK; if duplicate INSERT → throw `.invalidPayload` — каллер bug, тот же composite PK уже есть).
7. Implicit commit on block return; rollback on any throw.

**Sole-active guard relaxation:** в шаге 4 не делаем sole-active count check (как в 5.3.A `deprecateTeamKey`) потому что в шаге 3 уже инсерчена new active row — within same tx, `count(*) WHERE deprecated_at_ms IS NULL >= 2` ⇒ guard would pass.

### 4.4 `Database.markRotationOutboxPosted`

```swift
public func markRotationOutboxPosted(
    peerPubkeyHex: String,
    newKeyID: String,
    at postedAt: Date
) throws
```

Single `pool.write`:

1. Mode-guard.
2. UPDATE rotation_outbox SET posted_at_ms = ? WHERE peer_pubkey_hex = ? AND new_key_id = ? AND posted_at_ms IS NULL.
3. `changesCount` 0/1 — silent (idempotent on already-posted; tolerant on missing row для crash-resume race protection).

### 4.5 `Database.readUnpostedRotationOutboxRows`

```swift
public func readUnpostedRotationOutboxRows() throws -> [RotationOutboxRow]
```

Reader-mode safe (mirror `readActiveTeamKey`):

```sql
SELECT peer_pubkey_hex, new_key_id, prior_key_id, kind, peer_member_id, blob,
       expires_at_ms, created_at_ms, posted_at_ms
FROM rotation_outbox
WHERE posted_at_ms IS NULL
ORDER BY created_at_ms ASC, peer_pubkey_hex ASC
```

Secondary order by `peer_pubkey_hex` for deterministic test fixtures (multiple rows from same rotation event have identical `created_at_ms`).

### 4.6 `LeafError.cannotRemoveSelfFromTeam`

```swift
case cannotRemoveSelfFromTeam
```

Surfaced from `KeyRotationService.removeMember(memberID:)` preflight.

### 4.7 `KeyRotationService`

```swift
public struct KeyRotationService: Sendable {
    private let database: Database
    private let relayClient: RelayClient
    private let rotationKDF: any RotationKDF
    private let rotationBlobCodec: any RotationBlobCodec
    private let keystoreRoot: URL
    private let now: @Sendable () -> Date
    private let randomBytes: @Sendable (Int) throws -> Data
    private let randomUUID: @Sendable () -> String
    private let identity: @Sendable () throws -> Curve25519.KeyAgreement.PrivateKey

    public init(
        database: Database,
        relayClient: RelayClient,
        rotationKDF: any RotationKDF,
        rotationBlobCodec: any RotationBlobCodec,
        keystoreRoot: URL = TeamKeystore.defaultRoot(),
        now: @escaping @Sendable () -> Date = { Date() },
        randomBytes: @escaping @Sendable (Int) throws -> Data = KeyRotationService.secureRandom,
        randomUUID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        identity: (@Sendable () throws -> Curve25519.KeyAgreement.PrivateKey)? = nil
    )

    public func removeMember(memberID: String) async throws -> RotationOutcome
    public func resumePendingPosts() async throws -> RotationOutcome
    
    private func performRotation(removingMember: String?) async throws -> RotationOutcome
}
```

Factory injection mirror'ит `OrgService` / `InviteService` — деterministic tests через override.

---

## 5. Flows

### 5.1 `removeMember(memberID:)` end-to-end

```
1. Preflight (read-only):
   - readOrg() → org or throw .invalidPayload
   - selfMemberID = org.createdByMemberID
   - if memberID == selfMemberID → throw .cannotRemoveSelfFromTeam
   - readActiveTeamKey() → priorActiveKey or throw .invalidPayload
   - priorKeyID = priorActiveKey.id
   - activeMembers = readTeamMembers(orgID: org.id, includeRemoved: false)
   - if !activeMembers.contains(where: { $0.id == memberID }) → throw .invalidPayload
   - removedMember = activeMembers.first(where: { $0.id == memberID })  // guaranteed non-nil
   - priorTeamKeyBytes = TeamKeystore.readTeamKey(id: priorKeyID, at: keystoreRoot)

2. Generate (in-memory):
   - newKeyID = randomUUID()
   - newKeyIDData = UUID(uuidString: newKeyID)!.uuid as 16B Data
   - newTeamKeyBytes = randomBytes(32)
   - nowDate = now()
   - nowMs = Int64(nowDate.timeIntervalSince1970 * 1000)
   - expiresAtMs = nowMs + 24 * 60 * 60 * 1000
   - adminPriv = identity()

3. Compose blobs (in-memory loop, no I/O):
   var outboxRows: [RotationOutboxRow] = []
   for member in activeMembers:
     if member.id == selfMemberID: continue
     if member.id == removedMember.id:
       // .tombstone wrap
       wrapKey = SymmetricKey(data: priorTeamKeyBytes)         // raw prior, no HKDF (5.3.B AD #6)
       removedPubkey = Data(hex: member.pubkeyHex)              // 32B
       plaintext = RotationPlaintext(
         kind: .tombstone,
         newTeamKeyBase64: "",
         newKeyID: priorKeyID,                                  // == prior
         priorKeyID: priorKeyID,
         generatedAtMs: nowMs,
         removedMemberID: member.id
       )
       blob = rotationBlobCodec.encode(plaintext, recipientPubkey: removedPubkey, wrapKey: wrapKey)
       outboxRows.append(RotationOutboxRow(
         peerPubkeyHex: member.pubkeyHex,
         newKeyID: priorKeyID,
         priorKeyID: priorKeyID,
         kind: .tombstone,
         peerMemberID: member.id,
         blob: blob.bytes,
         expiresAtMs: expiresAtMs,
         createdAtMs: nowMs,
         postedAtMs: nil
       ))
     else:
       // .rotation wrap
       peerPubData = Data(hex: member.pubkeyHex)                // 32B
       peerPub = Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPubData)
       sharedSecret = adminPriv.sharedSecretFromKeyAgreement(with: peerPub)
       wrapKey = rotationKDF.deriveWrapKey(sharedSecret: sharedSecret, newKeyID: newKeyIDData)
       plaintext = RotationPlaintext(
         kind: .rotation,
         newTeamKeyBase64: newTeamKeyBytes.base64EncodedString(),
         newKeyID: newKeyID,
         priorKeyID: priorKeyID,
         generatedAtMs: nowMs,
         removedMemberID: nil
       )
       blob = rotationBlobCodec.encode(plaintext, recipientPubkey: peerPubData, wrapKey: wrapKey)
       outboxRows.append(RotationOutboxRow(
         peerPubkeyHex: member.pubkeyHex,
         newKeyID: newKeyID,
         priorKeyID: priorKeyID,
         kind: .rotation,
         peerMemberID: member.id,
         blob: blob.bytes,
         expiresAtMs: expiresAtMs,
         createdAtMs: nowMs,
         postedAtMs: nil
       ))

4. Keystore-first:
   try TeamKeystore.writeTeamKey(newTeamKeyBytes, id: newKeyID, at: keystoreRoot)
   // Orphan file < orphan rows. If step 5 fails, keystore has new key but DB unchanged.
   // Acceptable per 5.1.D contract; next attempt generates yet-another newKeyID, prior orphan stays.

5. Atomic DB tx:
   try database.commitRotation(
     newTeamKey: TeamKey(id: newKeyID, generatedAt: nowDate, deprecatedAt: nil, generatedByMemberID: selfMemberID),
     priorTeamKeyID: priorKeyID,
     deprecatedAt: nowDate,
     removedMemberID: removedMember.id,
     removedAt: nowDate,
     outboxRows: outboxRows
   )

6. POST iteration (best-effort, continue-on-error):
   var posted = 0
   var pending = 0
   for row in outboxRows:
     do:
       _ = try await relayClient.postRotationBlob(
         peerPubkeyHex: row.peerPubkeyHex,
         blob: row.blob,
         expiresAtMs: row.expiresAtMs
       )
       try database.markRotationOutboxPosted(
         peerPubkeyHex: row.peerPubkeyHex,
         newKeyID: row.newKeyID,
         at: now()
       )
       posted += 1
     catch:
       // log error; do NOT throw; continue
       pending += 1

7. Return RotationOutcome(
     newKeyID: newKeyID,
     priorKeyID: priorKeyID,
     postedCount: posted,
     pendingCount: pending,
     totalCount: outboxRows.count
   )
```

### 5.2 `resumePendingPosts()` flow

```
1. unposted = readUnpostedRotationOutboxRows()
   if unposted.isEmpty:
     return RotationOutcome(newKeyID: "", priorKeyID: "", postedCount: 0, pendingCount: 0, totalCount: 0)

2. Same continue-on-error loop as removeMember step 6.

3. Return aggregated RotationOutcome.
   - newKeyID: empty string ("" — multi-event resume could have multiple distinct newKeyIDs; surface as undefined)
   - priorKeyID: empty string
   - postedCount / pendingCount / totalCount: aggregated across all unposted rows iterated.
```

**Why empty `newKeyID`/`priorKeyID` in resume outcome:** resume может drain'ить rows from multiple historical rotation events (если сразу несколько failed). Surfacing single newKeyID was misleading. Empty string + caller treats outcome as "drain summary". UI 5.3.E может display "N pending POSTs drained" without referencing specific keys.

### 5.3 Atomicity / failure invariants

| Step | Failure | State after |
|---|---|---|
| Preflight read | throw | No state change |
| Compose blobs | throw (e.g. ECDH error) | No state change |
| Keystore write | throw | No state change in DB; orphan keystore file possible (dropped on next rotation) |
| `commitRotation` | throw | No state change in DB (atomic rollback); orphan keystore file from step 4 |
| `commitRotation` succeeds, POST fails | log + continue | DB tx committed (new active key, prior deprecated, member removed, N outbox rows). Pending POSTs drain on next `resumePendingPosts()` |
| App crashes mid-POST iteration | n/a | DB tx committed; outbox rows for un-POST'ed peers have `posted_at_ms IS NULL`. Next `resumePendingPosts()` drains. |
| Relay returns 500 | throw inside loop | Caught + logged + continue. Increments `pendingCount`. |
| Relay returns 400 (bad input) | throw inside loop | Caught + logged + continue. **WARNING**: 400 indicates admin-side bug (composed bad blob). Won't auto-retry успешно — peer will never get rotation. Diagnostic surface deferred (post-MVP Privacy Dashboard). |

---

## 6. Composition root (Agent.swift)

### 6.1 Wiring

```swift
// LeafAgent/Agent.swift, после InviteService block

let rotationKDF: any RotationKDF = {
    #if LEAF_PROD
    return ProdRotationKDF()
    #else
    return UnimplementedRotationKDF()
    #endif
}()

let rotationBlobCodec: any RotationBlobCodec = {
    #if LEAF_PROD
    return ProdRotationBlobCodec()
    #else
    return UnimplementedRotationBlobCodec()
    #endif
}()

let keyRotationService = KeyRotationService(
    database: database,
    relayClient: relayClient,
    rotationKDF: rotationKDF,
    rotationBlobCodec: rotationBlobCodec,
    keystoreRoot: keystoreRoot
)
```

### 6.2 Resume on startup

```swift
// Fire-and-forget — не блокируем Agent boot. Pending POSTs drain when network ready.
Task.detached {
    do {
        let outcome = try await keyRotationService.resumePendingPosts()
        if outcome.totalCount > 0 {
            // log via existing Agent logger
        }
    } catch {
        // log non-fatal
    }
}
```

### 6.3 Forward-compat для UI hookup (5.3.E)

`KeyRotationService` экспортируется через Agent через какой-то bridge — конкретный механизм (XPC? ObservableObject в shared package?) — концерн 5.3.E (where Remove-menu UI lives in `Leaf` target, not `LeafAgent`). 5.3.D wiring достаточен для resume on startup; UI plumbing — в 5.3.E.

---

## 7. Tests

### 7.1 Public SPM tests (Tests/LeafCoreTests)

`RotationOutboxRowTests.swift` (3 cases):
1. Equatable + Hashable round-trip.
2. PostedAtMs nil-vs-non-nil distinguish.
3. Composite (peerPubkeyHex, newKeyID) acts as natural key (manual hash).

`RotationOutcomeTests.swift` (2 cases):
1. Equatable round-trip.
2. Empty/zero outcome shape (resumePending all-clean case).

`DatabaseRotationOutboxTests.swift` (~10 cases):
1. `commitRotation_HappyPath_NewActiveOldDeprecated` — без removedMember; assert team_keys has 2 rows (new active + prior deprecated), no team_members change, N outbox rows present.
2. `commitRotation_WithRemovedMember_UpdatesAllThreeTables` — assert team_keys + team_members + outbox.
3. `commitRotation_WithoutRemovedMemberPasses_NilArgsValidate` — explicit nil→nil; throws if mismatched (`(nil, non-nil)` или `(non-nil, nil)`).
4. `commitRotation_FailsWhenPriorTeamKeyMissing` — throws `.invalidPayload`; rollback verified (no team_keys insert).
5. `commitRotation_FailsWhenPriorTeamKeyAlreadyDeprecated` — pre-deprecate prior, then commitRotation; throws `.invalidPayload`; rollback.
6. `commitRotation_FailsWhenRemovedMemberMissing` — throws `.invalidPayload`; rollback.
7. `commitRotation_FailsWhenRemovedMemberAlreadyRemoved` — throws `.invalidPayload`; rollback.
8. `commitRotation_FailsOnDuplicateOutboxRow` — pre-insert one outbox row with same (peer, new_key_id); commitRotation INSERT collides → throws.
9. `markRotationOutboxPosted_HappyPath` — UPDATE writes posted_at_ms.
10. `markRotationOutboxPosted_IsIdempotent` — re-call on already-posted preserves first timestamp (silent no-op).
11. `markRotationOutboxPosted_OnMissingRowSilent` — call on non-existent (peer, key) → no throw (idempotent for crash-resume).
12. `readUnpostedRotationOutboxRows_FiltersAndOrders` — mix of posted + unposted across 2 events; verify only unposted returned, ordered by created_at_ms.

`KeyRotationServiceTests.swift` (~12 cases):
1. `removeMember_HappyPath_TwoPeers_AllPosted` — fixtures: org + 3 active members (self + A + B); removeMember(B); URLProtocol stub returns 201 for both POSTs; verify outcome (postedCount=2, pendingCount=0, totalCount=2), DB state, outbox rows posted.
2. `removeMember_TombstoneShape` — verify `.tombstone` blob in outbox has kind=tombstone, peer=removed.pubkey, newKeyID==priorKeyID; `.rotation` blob for remaining peer has kind=rotation, newKeyID!=priorKeyID.
3. `removeMember_FailsOnSelfRemoval` — throws `.cannotRemoveSelfFromTeam` без any state change.
4. `removeMember_FailsOnMissingMember` — throws `.invalidPayload`.
5. `removeMember_FailsOnAlreadyRemovedMember` — pre-mark removed; throws `.invalidPayload`.
6. `removeMember_FailsOnNoOrg` — empty DB; throws `.invalidPayload`.
7. `removeMember_FailsOnNoActiveTeamKey` — fixtures w/o team_keys row; throws `.invalidPayload`.
8. `removeMember_PartialPostFailure_ContinuesAndReturnsPending` — URLProtocol stub returns 500 on first POST, 201 on second; verify outcome (postedCount=1, pendingCount=1), one outbox row has posted_at_ms set, other nil.
9. `removeMember_FullPostFailure_DBStateStillCommitted` — all POSTs fail; verify DB tx committed (team_keys + team_members updated), all outbox rows unposted, outcome (postedCount=0, pendingCount=N).
10. `removeMember_KeystoreFailureBeforeDB_NoStateChange` — inject failing keystore root URL (e.g. read-only); verify no DB change.
11. `resumePendingPosts_HappyPath_DrainsUnposted` — pre-seed outbox with 3 unposted rows; verify all marked posted after resume.
12. `resumePendingPosts_EmptyOutbox_NoOp` — verify zero outcome.
13. `resumePendingPosts_PartialDrainContinues` — relay 500 on second row, 201 on first + third; verify postedCount=2, pendingCount=1.

**Total SPM Δ:** ~25-30 new cases (3 + 2 + 12 + 13). Baseline 880 → ~905-910.

### 7.2 Moat E2E test (Tests/LeafCorePrivateTests, gitignored)

`RotationHandshakeIntegrationTests.swift` (~3 cases — full ProdRotationKDF + ProdRotationBlobCodec round-trip):

1. `testRemoveMemberHandshake_AdminBlobsDecryptOnPeerSide_ByteForByteTeamKey` — full simulated 2-Mac:
   - Setup: 2 in-memory DBs (admin + peer), 2 keystore roots, 2 X25519 keypairs, shared org/team_members fixtures.
   - Admin calls `removeMember(memberID: thirdParty)`.
   - URLProtocol stub captures POSTs.
   - For each captured POST: peer (using its X25519 priv) calls `RotationBlobHeader.peek` → derive wrapKey via `ProdRotationKDF.deriveWrapKey(sharedSecret(priv, admin.pub), newKeyID)` (или raw prior teamKey for tombstone) → `ProdRotationBlobCodec.decode` → assert plaintext.newTeamKeyBase64 base64-decodes to byte-for-byte match admin's newTeamKey.
2. `testRemoveMemberHandshake_TombstoneDecryptsForRemovedPeer` — third party (removed) similarly fetches own POST → wrapKey = raw prior teamKey from peer's keystore → decode → assert kind=tombstone, removedMemberID matches.
3. `testRemoveMemberHandshake_ResumePostsAreReplayedIdempotently` — admin removeMember → simulate POST failure on N peers → resumePendingPosts → URLProtocol now returns 201 → assert all outbox rows posted, rotation_id from relay matches first POST per composite key (idempotent at relay).

### 7.3 Test infrastructure

- **DB fixtures:** real SQLCipher temp file (`.deterministicTest` encryption mode), mirror `OrgServiceTests`/`InviteServiceTests`.
- **Keystore fixtures:** temp dir + `TeamKeystore.writeTeamKey` directly seeded.
- **URLSession mocking:** file-local `KeyRotationServiceMockURLProtocol` per file (mirror precedent — each test file owns its stub class to avoid cross-file static state).
- **Recording doubles:** `RecordingRotationKDF` + `RecordingRotationBlobCodec` для KeyRotationServiceTests (capture inputs, return stub blob bytes); moat E2E uses real `Prod*` impls.

---

## 8. Threat model + invariants

### 8.1 Capability model (unchanged from 5.3.B/C)

- Relay = honest-but-curious. POST'ed blobs are AES-GCM-256 ciphertext; relay sees only opaque bytes.
- Each blob unique per (admin, peer, rotation event) via composite-key dedup at relay (first-writer-wins).
- Tombstone forgeable by any current team member (wrapKey = shared prior teamKey). Acceptable per 5.3.B AD #6 — non-admin members already have full read access.

### 8.2 Atomicity invariants

- **Keystore-first ordering:** new teamKey bytes hit disk before any DB row references them. Crash between keystore write and DB tx → orphan file (dropped silently next rotation). DB row referencing missing keystore would break presence broadcast (5.4 future) — never happens.
- **Single-tx commitRotation:** new+deprecated teamKey + removed member + N outbox rows ARE atomically committed or atomically rolled back. No half-state.
- **POST iteration is post-commit:** rotation event fully realized in DB before any network call. App crash during POSTs leaves pending outbox rows for resume.

### 8.3 Idempotency invariants

- **`commitRotation` is NOT idempotent**: re-call after success will violate sole-active rule via prior key already deprecated → throws `.invalidPayload`. Admin should NOT re-call removeMember after success; instead `resumePendingPosts()` drains stale POSTs.
- **`markRotationOutboxPosted` IS idempotent**: re-call preserves first timestamp; missing row is silent no-op (tolerant for crash-resume race).
- **`postRotationBlob` POST IS idempotent at relay** (5.3.C composite-key dedup). Resume retry returns same `rotation_id`.

### 8.4 Sole-admin lockout protection

Admin cannot remove себя (preflight throws `.cannotRemoveSelfFromTeam`). Admin1 removing Admin2 — service permits; UI 5.3.E may add confirmation dialog.

### 8.5 Member ordering / deterministic blobs

`activeMembers` ordered by `added_at_ms` (per `readTeamMembers` 5.1.B contract). Outbox rows written in same iteration order. Determinism aids debugging.

---

## 9. Error semantics

| Error | Source | Caller surface |
|---|---|---|
| `.cannotRemoveSelfFromTeam` | `removeMember` preflight | UX 5.3.E surfaces "You cannot remove yourself" |
| `.invalidPayload` | preflight (no-org / no-active-key / member-missing / member-already-removed) или commitRotation (atomic violation) | UX surfaces generic "Rotation rejected" |
| `.databaseUnavailable` | reader-mode mutator call | bug — should never reach UI |
| `.relayUnreachable("transport"\|"server-error"\|"malformed-response")` | relayClient.postRotationBlob (5.3.C contract) | Caught + logged in POST loop; surfaces as `pendingCount` |
| `.rotationRequestRejected("bad-input"\|"size"\|"method"\|"media-type")` | relayClient.postRotationBlob 4xx | Caught + logged; surfaces as `pendingCount`. **Note**: "bad-input" indicates admin-side bug — won't recover via retry. Diagnostic surface = post-MVP. |
| `.rotationBlobMalformed` | Codec encode (e.g. bad recipientPubkey size) | Throws to caller; preflight should validate, but defensive |
| `.keyFileUnavailable` / `.keyFileCorrupted` | TeamKeystore read prior teamKey OR write new teamKey | Throws to caller before DB tx; safe (no DB change) |

---

## 10. Acceptance

### 10.1 Per-stage

- `swift test --package-path Packages/LeafCore` — all pass; numerical Δ matches plan (~+25-30 cases).
- `xcodebuild -scheme Leaf` / `LeafAgent` / `LeafMCP` / `LeafCore` / `LeafCorePrivate` — все BUILD SUCCEEDED.
- Independent code review (`superpowers:code-reviewer`) — APPROVED (or NEEDS-CHANGES → addressed → APPROVED).

### 10.2 Manual smoke

NONE требуется в 5.3.D. First end-to-end smoke = 5.3.E ship-gate two-Mac test.

### 10.3 Post-ship-stack ship-gate

5.3.D landed substrate-only — НЕ merge'ить feature/phase-5-3-D в main. Wait для 5.3.E ship-gate (decomposition pattern consistent с 5.1.A-E + 5.2.A-E + 5.3.A-C).

---

## 11. Out of scope

| Excluded | Reserved for |
|---|---|
| Peer fetch loop / RotationFetchService / RotationFetchScheduler | 5.3.E |
| TeamView Remove-menu UI / RemoveMemberSheet / RemovedFromTeamBanner | 5.3.E |
| OrgReader.removedFromOrg flag | 5.3.E |
| Two-Mac handshake smoke ship-gate | 5.3.E |
| Proactive rotation API (`rotate()`) | v1.1 |
| UI surface для resumePending failures (Privacy Dashboard) | post-MVP |
| Rate limiting на admin-side (admin spamming removeMember) | post-MVP if abuse signals в alpha |
| Multi-admin invariants (admin1 removing admin2 confirmation) | 5.3.E UI level |
| Rollback API (admin oops, want to un-remove member) | post-MVP if signal emerges; current path = re-invite via 5.2 |

---

## 12. Whitepaper sync

**NONE** — implementation moat (KeyRotationService internals + RotationOutbox schema + composition glue + atomic-tx pattern).

`presence-relay.md` уже описывает rotation flow абстрактно: admin removes member → key rotation → N-1 wraps. Service/orchestrator/journal layer — implementation detail, не уходит в public docs.

`storage.md` — table list уже отражает team_keys / team_members с момента 5.1.A. M009 `rotation_outbox` — ephemeral journal, не canonical state; добавлять в public table list = noise (consistent с `presence_state` M005 которая тоже not прописана в storage.md table list).

`changelog.md` — единственное изменение, которое могло бы быть, — высокоуровневая запись типа "Phase 5.3.D landed — admin orchestrator". Решение: **отложить changelog entry до Phase 5.3 ship'а в alpha.X** (5.3.E ship-gate). Pattern consistent с 5.1.A-E + 5.2.A-E + 5.3.A-C.

---

## 13. Forward dependencies (Phase 5.3.E hand-off)

### 5.3.E uses

- `KeyRotationService.removeMember` — consumer = TeamView Remove-menu action.
- `RotationOutcome` — UI surface для toast/dialog.
- `LeafError.cannotRemoveSelfFromTeam` — UI surface для inline alert.
- Existing 5.3.A `readTeamKey(byID:)` — peer fetch loop unwrap path для historical keyIDs.

### 5.3.E adds (NOT in 5.3.D scope)

- `RotationFetchService` — peer fetch loop; calls `relayClient.fetchPendingRotations` + `RotationBlobHeader.peek` discriminator + `rotationKDF.deriveWrapKey` (для `.rotation`) или raw prior teamKey (для `.tombstone`) + `rotationBlobCodec.decode` + `database.insertTeamKey` (with ON CONFLICT IGNORE or `insertTeamKeyIfAbsent` helper) + `database.deprecateTeamKey` + `relayClient.ackRotation`.
- `RotationFetchScheduler` — periodic tick (60s? 5min? fixed по precedent invite onceshot vs presence 60s — TBD 5.3.E spec).
- `OrgReader.removedFromOrg` Boolean flag — set когда peer fetches `.tombstone` для self.
- TeamView Remove-menu hookup → `KeyRotationService.removeMember`.
- `RemovedFromTeamBanner` — full-screen takeover при `OrgReader.removedFromOrg = true`. Org wipe option.

### 5.3.E known invariant note (per 5.3.C §10)

`Database.insertTeamKey` is **strict INSERT** per 5.1.B contract. На duplicate `id` (idempotent re-fetch case при mid-install crash) it throws. **5.3.E must wrap insertTeamKey call in try/catch** treating duplicate-id throw как success (idempotent install — peer fetches twice, second install no-op). Alternative: 5.3.E adds `Database.insertTeamKeyIfAbsent(...)` helper (additive 5.1.B extension). Decision deferred to 5.3.E spec.

---

## 14. Risks / open questions

| # | Risk | Mitigation |
|---|---|---|
| R1 | `Task.detached { resumePendingPosts() }` swallows errors silently | Acceptable — pending POSTs persist в outbox, next launch re-attempts. Diagnostic surface = post-MVP. Alpha smoke выявит если outbox растёт без bound. |
| R2 | Admin removes member while another admin (in same org) initiates concurrent removeMember | Single-org-per-device single-writer per Mac. Two Mac'ов — different sessions, **different newKeyIDs** generated. Race: both POST для overlap peers; relay first-writer-wins on composite key — second admin's blob silently swallowed. **Inconsistency**: Mac A peer holds first-writer's newKey; Mac B peer holds second-writer's newKey; conflict on next presence broadcast (different newKeys → can't decrypt cross-admin presence). **Mitigation**: out of MVP scope (multi-admin coordination — 5.3.E может add confirmation dialog "another admin is rotating, wait"). Alpha N=2-5 admins вряд ли trigger'ят race naturally. |
| R3 | `commitRotation` SQL inline duplicates SQL bodies of `insertTeamKey` / `deprecateTeamKey` / `markTeamMemberRemoved` | Acceptable — GRDB DatabasePool.write isn't reentrant; inlining sole way to maintain atomicity. Code review may flag — defensible per `writeEventsOffsetAndPresence` precedent. Maintenance: schema change в team_keys/team_members affects both helper SQL и commitRotation SQL. Schema constants reduce DRY pain. |
| R4 | `markRotationOutboxPosted` silent on missing row hides bug | Tolerated for crash-resume race protection (rare path: admin marks posted → app crashes → app relaunches и читает stale outbox cached in memory → calls markPosted again на already-purged-by-TTL row?). Defensive. |
| R5 | `postedAtMs` IS NULL filter on partial index not respected by some SQLite versions | Mitigated by `cipher_plaintext_header_size=32` SQLCipher build (well-tested). Test #12 verifies partial index actually filters. |
| R6 | RotationOutbox `blob` BLOB column не fits в SQLite default page size (4KB) | Single blob ~270B; N=49 peers → 13.5KB outbox total per rotation. Под SQLite 4KB page → multi-page row per blob, slight overhead. Acceptable; alternative (filesystem files) overengineering. |
| R7 | tombstone composite PK collision если two events both rotate-on-removal of same peer | Tombstone composite = `(removed.pubkey, prior_key_id)`. Second event would have different prior (because first event's new became second event's prior). Different composite. **No collision.** |
| R8 | `Curve25519.KeyAgreement.PublicKey(rawRepresentation:)` throws on bad pubkey | Member.pubkeyHex is 64-char hex validated at insertTeamMember time (5.1.B contract). Defensive throw on malformed → `.invalidPayload`. |

---

## 15. Pre-push checklist (`gundemtech/leaf` is public)

Before `git push origin feature/phase-5-3-D`:
- ❌ NO public diff exposes any moat constants from 5.3.B (HKDF info string, AAD layout) — все references abstract ("HKDF info string — moat constant"). Verified.
- ❌ NO public diff exposes byte offsets от RotationBlobHeader (всё в `LeafCorePrivate` уже).
- ❌ NO leaks of relay KV key prefix scheme или MAX_PENDING_PER_PEER cap (5.3.C moat).
- ✅ Public surface: schema (table/column/index names — already public per 5.1.A precedent для team_keys/team_members), service public API shapes, factory injection patterns, error types, atomic-tx contract.
- ✅ Test assertions cover *shape* (DB rows present/absent, outcome counts, error types), не secret values.

`/pre-push-leaf` MUST pass before push.

---

## 16. Commit decomposition (target ~14-15 commits)

1. `docs(specs): Phase 5.3.D — admin orchestrator + RotationOutbox spec` — this file.
2. `feat(core): Phase 5.3.D — M009 rotation_outbox migration + Schema namespace` + 1 sanity migration test.
3. `feat(core): Phase 5.3.D — RotationOutboxRow value type` + 3 tests.
4. `feat(core): Phase 5.3.D — RotationOutcome value type` + 2 tests.
5. `feat(core): Phase 5.3.D — LeafError.cannotRemoveSelfFromTeam` + 1 sanity test.
6. `feat(core): Phase 5.3.D — Database.commitRotation` + 8 tests.
7. `feat(core): Phase 5.3.D — Database.markRotationOutboxPosted` + 3 tests.
8. `feat(core): Phase 5.3.D — Database.readUnpostedRotationOutboxRows` + 1 test.
9. `feat(core): Phase 5.3.D — KeyRotationService scaffold + init + factories`.
10. `feat(core): Phase 5.3.D — KeyRotationService.performRotation (compose+keystore+commit)` + 7 tests.
11. `feat(core): Phase 5.3.D — KeyRotationService.removeMember (public + POST iteration)` + 3 tests.
12. `feat(core): Phase 5.3.D — KeyRotationService.resumePendingPosts` + 3 tests.
13. `feat(core/private): Phase 5.3.D — Rotation handshake integration test (gitignored moat)` + 3 tests.
14. `feat(agent): Phase 5.3.D — Agent.swift composition root + Task.detached resume on startup`.
15. `docs(shared): Phase 5.3.D landed — current-state update`.

---

*End of spec. Plan уровня commit-by-commit — следом, через `superpowers:writing-plans`.*
