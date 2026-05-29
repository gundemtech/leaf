# Phase 5.3.E — Peer fetch loop + UI Remove menu + RemovedFromTeamBanner

**Status:** Active (2026-05-06). Fifth (final) sub-phase of Phase 5.3 ("member removal + team key rotation"). Closes Phase 5.3 stack end-to-end.
**Owner:** Alex.
**Stack base:** `feature/phase-5-3-D` (5.3.D landed @ 835 SPM tests на этой машине / ~870-910 cross-machine canonical).
**Branch:** `feature/phase-5-3-E`.

---

## 1. Context

Phase 5.3 substrate готов на четырёх уровнях:
- 5.3.A — DB lifecycle mutators (`markTeamMemberRemoved` / `deprecateTeamKey` / `readTeamKey(byID:)`).
- 5.3.B — codec substrate (`RotationBlobCodec` + `RotationKDF` + `Prod*` impls — moat).
- 5.3.C — wire surface (`RelayClient.{postRotationBlob, fetchPendingRotations, ackRotation}` + leaf-relay endpoints + KV namespace).
- 5.3.D — admin orchestrator (`KeyRotationService.removeMember/resumePendingPosts` + M009 `rotation_outbox` + atomic `commitRotation` + Agent.swift composition root + Task.detached resume on startup).

Phase 5.3.E — **closing sub-phase**. Делает три things:

1. **Peer fetch loop** — `RotationFetchService` (LeafCore) periodically drain'ит peer-pubkey-keyed mailbox, peek-discriminate'ит каждый blob (rotation vs tombstone), деривирует wrapKey (ECDH+HKDF для rotation; raw prior teamKey для tombstone), decode'ит, install'ит локально (insertTeamKeyIfAbsent + deprecateTeamKey для rotation; markTeamMemberRemoved(self) для tombstone), ack'ит relay. Plus `RotationFetchScheduler` (LeafCore) — periodic tick mirror'ит `MaintenanceScheduler` actor pattern, opportunistic resume на каждом tick'е outgoing outbox.
2. **Member-removal UI** — `MemberRemovalReader` Observable (Leaf), `RemoveMemberSheet` confirmation modal, TeamView per-row "..." Menu trigger.
3. **Removed-from-org banner** — `OrgReader` augmentation: на refresh detect'ит self.removed_at_ms != nil → state `.removedFromOrg(orgName:)`. `RemovedFromTeamBanner` view full-screen takeover в RootView.

Plus один additive DB helper — `Database.insertTeamKeyIfAbsent(_:)` — закрывает 5.3.C §10 invariant note (idempotent re-fetch на mid-install crash).

Plus `agentThresholds.rotationFetchIntervalSec: TimeInterval = 60` tunable.

Без 5.3.E peer Mac'у нет способа учесть admin's removeMember. 5.3.E замыкает handshake admin↔peer end-to-end.

**Источники правды (priority при противоречии):**

1. `2026-05-04-phase-5-architecture-contract.md` §5 (trust model — peers mutually trusted) + §7 (key lifecycle — forever-retained team_keys) + §10 (failure modes — rejection logging + reconnect) + §12 (envelope versioning).
2. `2026-05-04-phase-5-3-A-db-mutators.md` §11 (forward dependency note — `readTeamKey(byID:)` consumer = 5.3.E).
3. `2026-05-04-phase-5-3-B-rotation-codec.md` §3 (wire format) + §10 (tombstone semantics — wrapKey = raw prior teamKey, no HKDF).
4. `2026-05-04-phase-5-3-C-relay-rotation.md` §3.2 (GET drain semantics — list-then-ACK) + §6.4 (mid-install crash protection) + §10 (forward-compat hand-off — `Database.insertTeamKey` strict INSERT throws on duplicate; 5.3.E adds `insertTeamKeyIfAbsent` helper).
5. `2026-05-04-phase-5-3-D-admin-orchestrator.md` §13 (forward dependency to 5.3.E).
6. `Packages/LeafCore/Sources/LeafCore/Agent/MaintenanceScheduler.swift` — actor scheduler template (init / start / stop / Task.cancel-aware).
7. `Leaf/Models/InviteOutboxReader.swift` + `Leaf/Models/InviteAcceptReader.swift` — Observable lazy-init pattern для UI bridge to KeyRotationService.
8. `Leaf/Views/Window/Team/GenerateInviteSheet.swift` + `Leaf/Views/Window/Organization/AcceptInviteSheet.swift` — sheet UI template.

---

## 2. Scope

### Входит

#### `gundemtech/leaf` (Swift, SPM + Agent + Leaf targets)

| Артефакт | Файл | Заметка |
|---|---|---|
| `Database.insertTeamKeyIfAbsent(_:)` | `Packages/LeafCore/Sources/LeafCore/DB/Database.swift` (edit, secured `// MARK: - Team (Phase 5.1.B)` block) | `INSERT ... ON CONFLICT(id) DO NOTHING`. Mode-guarded writer. Idempotent на duplicate id. |
| `RotationFetchOutcome` value type | `Packages/LeafCore/Sources/LeafCore/Team/RotationFetchOutcome.swift` (новый) | `{fetched, installed, tombstoneApplied, skipped: Int}`. Sendable, Hashable. |
| `RotationFetchService` | `Packages/LeafCore/Sources/LeafCore/Team/RotationFetchService.swift` (новый) | Public struct. Factory injection. Public `tick() async -> RotationFetchOutcome`. |
| `RotationFetchScheduler` | `Packages/LeafCore/Sources/LeafCore/Agent/RotationFetchScheduler.swift` (новый) | Actor mirror'ит MaintenanceScheduler. `init(fetchService, keyRotationService, intervalSec, logger)`. |
| `agentThresholds.rotationFetchIntervalSec` | `Packages/LeafCore/Sources/LeafCore/Agent/AgentThresholds.swift` (edit) | New stored property, default 60. `weakDefaults` updated. |
| `agentThresholds.rotationFetchIntervalSec` prod copy | `Packages/LeafCore/Sources/LeafCorePrivate/Prod/Configs/AgentThresholdsProd.swift` (edit, **gitignored**) | Default 60 carried to prod copy. |
| `OrgReader.State.removedFromOrg(orgName:)` case + refresh logic | `Leaf/Models/OrgReader.swift` (edit) | Self-pubkey lookup in team_members → check removed_at_ms. New State case. New userFacingMessage path для tombstone-induced state. |
| `MemberRemovalReader` Observable | `Leaf/Models/MemberRemovalReader.swift` (новый) | State machine `.idle / .removing(displayName) / .success(outcome) / .error(message)`. Lazy `ensureService` mirror InviteOutboxReader. |
| `RemoveMemberSheet` view | `Leaf/Views/Window/Team/RemoveMemberSheet.swift` (новый) | Modal with confirmation copy + state-routed body + Cancel/Remove footer. |
| `RemovedFromTeamBanner` view | `Leaf/Views/RemovedFromTeamBanner.swift` (новый) | Full-screen takeover. Info-only (wipe action — out of MVP). |
| `TeamView.memberRow` Menu trigger | `Leaf/Views/Window/Team/TeamView.swift` (edit) | Per-row "..." Menu (`Image(systemName: "ellipsis.circle")`); skipped для self-row. |
| RootView wiring | `Leaf/Views/RootView.swift` (edit) | Detect `orgReader.state == .removedFromOrg` → render `RemovedFromTeamBanner` instead of normal content. |
| LeafApp wiring | `Leaf/LeafApp.swift` (edit) | `@State memberRemovalReader = MemberRemovalReader()` + `.environment(...)` для main Window scene only (NOT MenuBarExtra — Remove flow lives в Team tab). |
| Agent.swift composition root | `LeafAgent/Agent.swift` (edit) | After 5.3.D KeyRotationService block: instantiate `RotationFetchService` + `RotationFetchScheduler(intervalSec: agentThresholds.rotationFetchIntervalSec)`. AgentLifetime slot. start/stop. |
| Public tests | `Packages/LeafCore/Tests/LeafCoreTests/{RotationFetchOutcome, DatabaseInsertTeamKeyIfAbsent, RotationFetchService, RotationFetchScheduler}Tests.swift` + Leaf target manual tests за пределами SPM | ~30-40 SPM cases new |
| Moat E2E test extension | `Packages/LeafCore/Tests/LeafCorePrivateTests/RotationHandshakeIntegrationTests.swift` (edit, **gitignored**) | Add 1-2 cases: peer-side install via real `RotationFetchService.tick`. |

### НЕ входит (явно отложено)

- **Wipe local team data** action в `RemovedFromTeamBanner` — info-only banner; wipe → post-MVP via Settings sweep. Banner copy explicitly references "wipe local team data via Settings" будущее но без implementation.
- **OrgReader writer-process write coordination** (single-org-per-device invariant + multi-process writer race на same DB). SQLite WAL serializes writers via POSIX locks per architecture.md ADR-017. Acceptable.
- **Privacy Dashboard surface для skipped fetches** (decode-fail-no-ack diagnostic) — post-MVP, mirror'ит 5.3.D R1 deferment pattern.
- **WS broadcast loop** (`ProdEnvelopeCodec` first real consumer) — Phase 5.4.
- **Onboarding screen 6 final integration** ("Team — join via invite OR create personal org") — Phase 5.5.
- **Multi-admin race confirmation dialog** ("another admin is rotating, wait") — out of MVP per 5.3.D R2 deferment.
- **Sole-admin lockout invariant** на UI (admin can remove other admin via service per 5.3.D §13). UI doesn't add extra confirmation; service guards sole-self preflight.
- **Rate limiting на admin-side spam** (admin clicking remove repeatedly) — relay TTL+composite-key dedup adequate; UI may add basic debounce in 5.5 but not 5.3.E.
- **In-place wipe** of `events.sqlite` + keystore on tombstone receipt (full local data dump) — info-only banner; user manually wipes via "Remove member" Sparkle-style data reset (post-MVP).
- **MCPServer / MenuBarExtra surface для removedFromOrg** — main Window only. MenuBarExtra continues to show ambient memory data (forever-retained per contract §12). MCPServer keeps responding.

---

## 3. Database addition

### 3.1 `insertTeamKeyIfAbsent`

```swift
// Packages/LeafCore/Sources/LeafCore/DB/Database.swift
// MARK: - Team (Phase 5.1.B), append after `insertTeamKey`

/// Idempotent variant of `insertTeamKey`. Used by Phase 5.3.E `RotationFetchService`
/// для crash-resilient install: peer fetches blob → unwraps → `insertTeamKeyIfAbsent`
/// (succeeds on first install, no-op on retry after crash mid-`deprecateTeamKey`).
/// Phase 5.3.C §10 invariant: composite-key dedup at relay means peer may receive
/// same blob twice; second `insertTeamKey` would throw on PK collision; this helper
/// swallows that path silently.
public func insertTeamKeyIfAbsent(_ key: TeamKey) throws {
    guard mode == .writer else { throw LeafError.databaseUnavailable }
    try pool.write { db in
        try db.execute(sql: """
            INSERT INTO \(Schema.TeamKeys.tableName) (
                \(Schema.TeamKeys.id),
                \(Schema.TeamKeys.generatedAtMs),
                \(Schema.TeamKeys.deprecatedAtMs),
                \(Schema.TeamKeys.generatedByMemberID)
            ) VALUES (?, ?, ?, ?)
            ON CONFLICT(\(Schema.TeamKeys.id)) DO NOTHING
            """,
            arguments: [
                key.id,
                Int64(key.generatedAt.timeIntervalSince1970 * 1000),
                key.deprecatedAt.map { Int64($0.timeIntervalSince1970 * 1000) },
                key.generatedByMemberID
            ]
        )
    }
}
```

**Why ON CONFLICT vs try/catch:** explicit semantic at DB layer; reader doesn't need to discriminate "insert succeeded" vs "no-op duplicate"; lower coupling between codec/service layer и SQL error stream. Consistent с `Database.upsertOrg` UPSERT discipline.

**`db.changesCount` after no-op** = 0; caller doesn't inspect (idempotency requires no caller-visible difference).

### 3.2 No new migration

M009 (5.3.D rotation_outbox) — last migration. 5.3.E does not add new tables / columns / indexes.

---

## 4. `RotationFetchOutcome`

```swift
// Packages/LeafCore/Sources/LeafCore/Team/RotationFetchOutcome.swift

/// Phase 5.3.E — return type для `RotationFetchService.tick()`.
/// Surface aggregate counts для logging + (future) Privacy Dashboard.
public struct RotationFetchOutcome: Sendable, Hashable {
    /// Total blobs returned by relay's GET drain.
    public let fetched: Int
    /// `.rotation` blobs successfully decoded + installed.
    public let installed: Int
    /// `.tombstone` blobs successfully decoded + applied (self marked removed).
    public let tombstoneApplied: Int
    /// Blobs skipped due to peek failure / decode failure (no admin worked) /
    /// keystore lookup failure. Skipped blobs are NOT acked → relay TTL purges
    /// or admin re-POST recovers.
    public let skipped: Int

    public init(fetched: Int, installed: Int, tombstoneApplied: Int, skipped: Int) { ... }

    public static let empty = RotationFetchOutcome(
        fetched: 0, installed: 0, tombstoneApplied: 0, skipped: 0
    )
}
```

---

## 5. `RotationFetchService`

### 5.1 Surface

```swift
// Packages/LeafCore/Sources/LeafCore/Team/RotationFetchService.swift
import Foundation
import CryptoKit

/// Phase 5.3.E — peer-side counterpart to 5.3.D `KeyRotationService`. Drains
/// pending key-rotation blobs from relay (peer-pubkey-keyed mailbox), unwraps
/// each (ECDH+HKDF for `.rotation`, raw prior teamKey for `.tombstone`), installs
/// locally (idempotent), and acks the relay.
///
/// Discriminator: `header.priorKeyID == header.newKeyID` ⇒ `.tombstone` (no
/// new teamKey to install; mark self removed). Otherwise `.rotation` (try
/// each admin pubkey for ECDH+HKDF until decrypt succeeds).
///
/// Idempotency: `insertTeamKeyIfAbsent` swallows duplicate-id; `markTeamMemberRemoved`
/// silently no-ops on already-removed; ack failure → next tick retries (relay
/// idempotent on DELETE).
///
/// Public API:
/// - `tick() async -> RotationFetchOutcome` — single fetch+install pass.
public struct RotationFetchService: Sendable {
    private let database: Database
    private let relayClient: RelayClient
    private let rotationKDF: any RotationKDF
    private let rotationBlobCodec: any RotationBlobCodec
    private let keystoreRoot: URL
    private let now: @Sendable () -> Date
    private let identity: @Sendable () throws -> Curve25519.KeyAgreement.PrivateKey

    public init(
        database: Database,
        relayClient: RelayClient,
        rotationKDF: any RotationKDF,
        rotationBlobCodec: any RotationBlobCodec,
        keystoreRoot: URL = TeamKeystore.defaultRoot(),
        now: @escaping @Sendable () -> Date = { Date() },
        identity: (@Sendable () throws -> Curve25519.KeyAgreement.PrivateKey)? = nil
    ) { ... }

    public func tick() async -> RotationFetchOutcome
}
```

### 5.2 Tick algorithm

```
1. Preflight (graceful no-op if no org / no self-member):
   org = try? database.readOrg()
   guard org != nil else { return .empty }
   selfPriv = try? identity()
   guard selfPriv != nil else { return .empty }
   selfPubHex = lowercased hex of selfPriv.publicKey.rawRepresentation

2. Drain mailbox:
   blobs = try? await relayClient.fetchPendingRotations(forPeerPubkeyHex: selfPubHex)
   guard let blobs else { return .empty }    // network/relay error → silent
   if blobs.isEmpty { return .empty }

3. Iterate (continue-on-error, accumulate counts):
   var installed = 0, tombstoneApplied = 0, skipped = 0
   for fetched in blobs:
     do {
       let header = try RotationBlobHeader.peek(from: RotationBlob(bytes: fetched.blob))
     } catch {
       skipped += 1; continue                  // bad version / short bytes
     }

     // Discriminator
     if header.priorKeyID == header.newKeyID {
       // Tombstone path
       processTombstone(blob: fetched.blob, header: header) → bool
       if applied {
         tombstoneApplied += 1
         try? await relayClient.ackRotation(rotationID: fetched.rotationID)
       } else {
         skipped += 1                          // do NOT ack; let TTL retire blob
       }
     } else {
       // Rotation path
       processRotation(blob: fetched.blob, header: header, orgID: org.id, selfPriv: selfPriv) → bool
       if applied {
         installed += 1
         try? await relayClient.ackRotation(rotationID: fetched.rotationID)
       } else {
         skipped += 1
       }
     }

4. Return RotationFetchOutcome(
     fetched: blobs.count,
     installed, tombstoneApplied, skipped
   )
```

### 5.3 `processTombstone` (private)

```
1. Convert priorKeyID Data 16B → UUID lowercase string. Throw .rotationBlobMalformed on bad UUID.
2. Read prior teamKey from local keystore (id = priorKeyID UUID).
   Failure (file missing / corrupted) → return false (skip).
3. Decode blob with wrapKey = SymmetricKey(data: priorTeamKeyBytes).
   AES-GCM tag fail → return false.
4. Cross-field assertion: `plaintext.kind == .tombstone`. Mismatch → return false (forged blob).
5. Cross-field assertion: `plaintext.removedMemberID != nil` (codec already enforces; defensive).
6. Cross-check: `plaintext.removedMemberID` must reference *self* —
   readTeamMembers(orgID, includeRemoved: true) → find member where pubkey matches selfPubHex →
   if member.id != removedMemberID → return false (mis-routed blob; do NOT trust to
   remove someone else).
7. Mark self removed: try database.markTeamMemberRemoved(memberID: selfMember.id, at: now())
   Swallow error logged (idempotent — already-removed is fine).
8. Return true.
```

### 5.4 `processRotation` (private)

```
1. Convert newKeyID Data 16B → UUID lowercase string. Throw → return false.
2. Get admin candidates: readTeamMembers(orgID, includeRemoved: false) → filter
   { $0.role == .admin && $0.pubkeyHex != selfPubHex }
   (Self can be admin in own org; iterate other admins. If self is sole admin
   и no peer admin to ECDH with, return false — but в 5.3 era peer is not
   founder rotating tombstone for self-removal — caller-bug. Defensive skip.)
3. For each admin in admins:
     do {
       let sharedSecret = try KeyAgreement.sharedSecret(
         privateKey: selfPriv,
         peerPublicKeyHex: admin.pubkeyHex
       )
       let wrapKey = try rotationKDF.deriveWrapKey(sharedSecret: sharedSecret, newKeyID: header.newKeyID)
       let plaintext = try rotationBlobCodec.decode(RotationBlob(bytes: blob), wrapKey: wrapKey)
       // Success — break loop
       return install(plaintext, newKeyID: newKeyIDString, priorKeyID: priorKeyIDString, generatedByAdminID: admin.id)
     } catch {
       continue   // try next admin
     }
   // All admins exhausted
   return false

4. install(plaintext, newKeyID, priorKeyID, generatedByAdminID) → bool:
   a. Cross-field assertion: plaintext.kind == .rotation, newTeamKeyBase64 length matches.
   b. Decode newTeamKeyBytes from base64. Must be 32B. Mismatch → false.
   c. Keystore-first: try TeamKeystore.writeTeamKey(newTeamKeyBytes, id: newKeyID, at: keystoreRoot).
      Failure → false. (Orphan file < orphan rows per 5.1.D contract.)
   d. DB tx: 
      try database.insertTeamKeyIfAbsent(TeamKey(id: newKeyID, generatedAt: now,
        deprecatedAt: nil, generatedByMemberID: generatedByAdminID))
      try database.deprecateTeamKey(keyID: priorKeyID, at: now)
        // If priorKeyID already deprecated (re-fetch race) → idempotent no-op via 5.3.A semantic.
        // If priorKeyID missing in local team_keys → throws .invalidPayload — caller skip.
      Both throws → false (after keystore write — orphan file remains, harmless).
   e. Return true.
```

### 5.5 Concurrency / threading

- `RotationFetchService` is `Sendable` struct. `tick()` runs entirely async — no internal lock'и.
- Database `pool.write` blocks coordinated by GRDB DatabasePool + SQLite WAL (cross-process POSIX lock).
- `RotationFetchScheduler` is the only caller; scheduler runs single tick at a time (not parallel).

---

## 6. `RotationFetchScheduler`

```swift
// Packages/LeafCore/Sources/LeafCore/Agent/RotationFetchScheduler.swift
import Foundation
import os

/// Phase 5.3.E — periodic peer-side fetch loop. Drains pending rotations from
/// relay + opportunistically resumes admin-side outgoing outbox.
///
/// Mirror MaintenanceScheduler actor pattern — single Task loop, await-on-cancel
/// shutdown, weak-self capture. Initial tick at half-interval (mirror retention
/// sweep loop) so first fetch happens within ~30s of Agent start.
public actor RotationFetchScheduler {
    private let fetchService: RotationFetchService
    private let keyRotationService: KeyRotationService
    private let intervalSec: TimeInterval
    private let logger: Logger

    private var task: Task<Void, Never>?

    public init(
        fetchService: RotationFetchService,
        keyRotationService: KeyRotationService,
        intervalSec: TimeInterval,
        logger: Logger
    ) { ... }

    public func start() {
        if task != nil { return }
        task = Task { [weak self] in
            await self?.runLoop()
        }
        logger.info("RotationFetchScheduler started (every=\(self.intervalSec, privacy: .public)s)")
    }

    public func stop() async {
        task?.cancel()
        await task?.value
        task = nil
        logger.info("RotationFetchScheduler stopped")
    }

    public func performTick() async {
        let outcome = await fetchService.tick()
        if outcome.fetched > 0 || outcome.installed > 0 || outcome.tombstoneApplied > 0 || outcome.skipped > 0 {
            logger.info("rotation fetch tick: fetched=\(outcome.fetched, privacy: .public) installed=\(outcome.installed, privacy: .public) tombstoneApplied=\(outcome.tombstoneApplied, privacy: .public) skipped=\(outcome.skipped, privacy: .public)")
        }
        do {
            let resume = try await keyRotationService.resumePendingPosts()
            if resume.totalCount > 0 {
                logger.info("rotation outbox resume: posted=\(resume.postedCount, privacy: .public) pending=\(resume.pendingCount, privacy: .public)")
            }
        } catch {
            logger.error("rotation outbox resume failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func runLoop() async {
        await sleep(seconds: intervalSec / 2)
        while !Task.isCancelled {
            await performTick()
            await sleep(seconds: intervalSec)
        }
    }

    private func sleep(seconds: TimeInterval) async {
        let ns = UInt64(max(0, seconds) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: ns)
    }
}
```

---

## 7. `AgentThresholds.rotationFetchIntervalSec`

`Packages/LeafCore/Sources/LeafCore/Agent/AgentThresholds.swift` — add new stored property + init param + weakDefaults entry:

```swift
/// Phase 5.3.E: as often as `RotationFetchScheduler` polls relay's
/// /v1/key-rotation/by-peer/* mailbox + opportunistically resumes admin-side
/// rotation_outbox. Default 60s — consistent с presence WS heartbeat в 5.4
/// contract; member-removal latency feels live-team.
public let rotationFetchIntervalSec: TimeInterval

// init: rotationFetchIntervalSec: TimeInterval = 60
// weakDefaults: rotationFetchIntervalSec: 60
```

`Packages/LeafCore/Sources/LeafCorePrivate/Prod/Configs/AgentThresholdsProd.swift` (gitignored) — append to `static let agent = AgentThresholds(...)` initializer with same default 60.

---

## 8. `OrgReader.removedFromOrg` mechanism (no schema change)

### 8.1 State machine extension

```swift
@Observable
final class OrgReader {
    enum State {
        case loading
        case empty
        case loaded(Org, [TeamMember])
        case removedFromOrg(orgName: String)        // NEW
        case error(message: String)
    }
    // ...
}
```

### 8.2 `refresh()` augmentation

```swift
func refresh() {
    do {
        let db = try ensureDatabase()
        guard let org = try db.readOrg() else {
            state = .empty
            return
        }
        // NEW: detect tombstone-applied state via self-member removed_at_ms.
        let allMembers = try db.readTeamMembers(orgID: org.id, includeRemoved: true)
        let priv = try IdentityService.ensureLocalIdentity(at: keystoreRoot)
        let myPubHex = priv.publicKey.rawRepresentation
            .map { String(format: "%02x", $0) }.joined()
        if let selfMember = allMembers.first(where: { $0.pubkeyHex == myPubHex }),
           selfMember.removedAt != nil {
            state = .removedFromOrg(orgName: org.name)
            return
        }
        let activeMembers = allMembers.filter { $0.removedAt == nil }
        state = .loaded(org, activeMembers)
    } catch {
        logger.error("OrgReader.refresh failed: \(String(describing: error), privacy: .public)")
        state = .error(message: userFacingMessage(for: error))
    }
}
```

`userFacingMessage` — no new path needed (existing dispatch sufficient).

### 8.3 Polling cadence

`OrgReader.refresh()` already invoked в:
- `OrganizationView.onAppear` / `TeamView.onAppear`.
- `AcceptInviteSheet` Done button.
- `MemberRemovalReader` success closure (5.3.E new).

For tombstone-induced removedFromOrg state to surface promptly после Agent's `RotationFetchScheduler` tick (which mutates DB on peer side), main app must re-call `refresh()`. Approaches:

- **(a)** UI poll on visibility: SwiftUI `.onAppear` of RootView triggers refresh каждый раз. Acceptable — tab reveal events happen frequently.
- **(b)** TimelineView periodic refresh (e.g., каждые 10s on RootView).
- **(c)** Inter-process notification from Agent → main app (DistributedNotificationCenter).

**Recommendation (a):** rely on `.onAppear`. If user doesn't open the app, "you've been removed" doesn't surface — but no presence is being broadcast anyway (Agent stops after marking self removed via tombstone path? Actually — tombstone only marks self in DB; Agent continues running; presence broadcast not yet wired up в 5.3.E). For 5.3.E scope, `.onAppear` is sufficient. Phase 5.4 (presence broadcast) adds proactive channel.

**Augmentation:** add explicit `refresh()` call в `RootView.body.onAppear` (not just inside child views). Cheap operation.

---

## 9. UI surfaces (Leaf target)

### 9.1 `MemberRemovalReader` (Leaf/Models/)

```swift
@MainActor
@Observable
final class MemberRemovalReader {
    enum State: Equatable {
        case idle
        case removing(displayName: String)
        case success(outcome: RotationOutcome, displayName: String)
        case error(message: String)
    }
    private(set) var state: State = .idle

    private var service: KeyRotationService?
    private var database: LeafCore.Database?
    // ... env-injects mirror InviteOutboxReader ...

    init(
        databaseURL: URL = DatabasePath.defaultURL(),
        databaseConfig: DatabaseConfig = ...,
        databaseEncryption: EncryptionOptions? = ...,
        keystoreRoot: URL = TeamKeystore.defaultRoot(),
        rotationKDF: any RotationKDF = ...,
        rotationBlobCodec: any RotationBlobCodec = ...
    )

    func removeMember(memberID: String, displayName: String) {
        state = .removing(displayName: displayName)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let svc = try self.ensureService()
                let outcome = try await svc.removeMember(memberID: memberID)
                self.state = .success(outcome: outcome, displayName: displayName)
            } catch {
                self.logger.error("removeMember failed: \(...)")
                self.state = .error(message: self.userFacingMessage(for: error))
            }
        }
    }

    func dismiss() { state = .idle }

    private func ensureService() throws -> KeyRotationService { ... lazy init ... }

    private func userFacingMessage(for error: Error) -> String {
        // .cannotRemoveSelfFromTeam → "You can't remove yourself from your own team."
        // .invalidPayload → "Couldn't remove member. State may be out of sync."
        // .relayUnreachable → "Couldn't reach the relay (...). Member removed locally; rotation will retry."
        //   ← (note: rotation already committed locally; pending POSTs drain on next tick)
        // default → generic
    }

    nonisolated private static func defaultConfig() / defaultEncryption() / defaultRotationKDF() / defaultRotationBlobCodec() — mirror InviteOutboxReader.
}
```

### 9.2 `RemoveMemberSheet`

Mirror'ит GenerateInviteSheet structure: header / state-routed content ViewBuilder / footer.

```swift
struct RemoveMemberSheet: View {
    @Environment(MemberRemovalReader.self) private var reader
    @Environment(OrgReader.self) private var orgReader
    @Environment(\.dismiss) private var dismiss
    let memberID: String
    let displayName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            content
            Spacer(minLength: 0)
            footer
        }
        .padding(28)
        .frame(width: 520, height: 380)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("REMOVE MEMBER").leafLabelStyle()
            Text("Remove \(displayName) from the team?")
                .font(.leafHeadline).foregroundStyle(.leafInk)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch reader.state {
        case .idle:
            confirmCard
        case .removing(let dn):
            confirmCard.disabled(true)
            HStack { Spacer(); ProgressView("Rotating team key…"); Spacer() }
        case .success(let outcome, let dn):
            successCard(dn: dn, outcome: outcome)
        case .error(let message):
            errorCard(message: message)
        }
    }

    private var confirmCard: some View {
        GlassCard(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                Text("This rotates the team key. \(displayName) won't be able to send presence under the previous key. They'll see a 'You've been removed' message in their app on next sync.")
                    .font(.leafBody).foregroundStyle(.leafInk).lineSpacing(3)
            }
        }
    }

    private func successCard(dn: String, outcome: RotationOutcome) -> some View {
        GlassCard(padding: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Removed \(dn)", systemImage: "checkmark.circle.fill")
                    .font(.leafHeadline).foregroundStyle(.green)
                if outcome.pendingCount > 0 {
                    Text("\(outcome.postedCount) of \(outcome.totalCount) peers notified. \(outcome.pendingCount) will sync when online.")
                        .font(.leafBody).foregroundStyle(.leafInk.opacity(0.85))
                } else {
                    Text("All \(outcome.postedCount) peer\(outcome.postedCount == 1 ? "" : "s") notified.")
                        .font(.leafBody).foregroundStyle(.leafInk.opacity(0.85))
                }
            }
        }
    }

    private func errorCard(message: String) -> some View { ... }

    private var footer: some View {
        HStack {
            Button("Cancel") { reader.dismiss(); dismiss() }
                .buttonStyle(.bordered)
            Spacer()
            switch reader.state {
            case .idle:
                Button("Remove") { reader.removeMember(memberID: memberID, displayName: displayName) }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            case .removing:
                Button("Remove") { }.disabled(true).buttonStyle(.borderedProminent)
            case .success:
                Button("Done") {
                    orgReader.refresh()
                    reader.dismiss()
                    dismiss()
                }.buttonStyle(.borderedProminent)
            case .error:
                Button("Close") { reader.dismiss(); dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
```

### 9.3 `RemovedFromTeamBanner`

Full-screen takeover, rendered in `RootView` based on orgReader state:

```swift
struct RemovedFromTeamBanner: View {
    let orgName: String

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 64))
                .foregroundStyle(.leafAccent)
            VStack(spacing: 12) {
                Text("You've been removed from \(orgName)")
                    .font(.leafHeadline)
                    .foregroundStyle(.leafInk)
                Text("Your local data remains on this device, but you can no longer send presence to teammates. To start fresh, wipe local team data via Settings (coming soon).")
                    .font(.leafBody)
                    .foregroundStyle(.leafInk.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .frame(maxWidth: 480)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.leafBg.ignoresSafeArea())
    }
}
```

### 9.4 `TeamView.memberRow` Menu trigger

Add trailing `Menu` button before `Spacer()`:

```swift
private func memberRow(_ member: TeamMember) -> some View {
    HStack(spacing: 14) {
        avatar(for: member.displayName)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) { ... }
            Text(pubkeyShortHex(member.pubkeyHex))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.leafInk.opacity(0.55))
        }
        Spacer()
        if member.pubkeyHex != myPubHex {           // skip self
            Menu {
                Button("Remove from team…", role: .destructive) {
                    pendingRemoval = (memberID: member.id, displayName: member.displayName)
                    showingRemoveSheet = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.leafInk.opacity(0.5))
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
        }
    }
}
```

`@State private var showingRemoveSheet = false` + `@State private var pendingRemoval: (memberID: String, displayName: String)?`.

`myPubHex` — computed lazily в `body.onAppear` через IdentityService (mirror AcceptInviteSheet `loadMyPubkey` pattern). Cached as `@State`.

`.sheet(isPresented: $showingRemoveSheet)` renders `RemoveMemberSheet(memberID: ..., displayName: ...)`.

### 9.5 RootView wiring

```swift
struct RootView: View {
    @Environment(OrgReader.self) private var orgReader
    // ... rest ...

    var body: some View {
        Group {
            switch orgReader.state {
            case .removedFromOrg(let orgName):
                RemovedFromTeamBanner(orgName: orgName)
            default:
                normalContent  // existing tab-based body
            }
        }
        .onAppear { orgReader.refresh() }
    }
}
```

### 9.6 LeafApp env wiring

```swift
@State private var memberRemovalReader = MemberRemovalReader()

// в Window scene only (NOT MenuBarExtra):
Window("Leaf", id: "main") {
    RootView()
        ...
        .environment(memberRemovalReader)        // NEW
        ...
}
```

---

## 10. Composition root (Agent.swift)

After 5.3.D KeyRotationService block (line 244-259), append:

```swift
let rotationFetchService = RotationFetchService(
    database: database,
    relayClient: rotationRelayClient,                // reuse from 5.3.D
    rotationKDF: rotationKDF,                        // reuse from 5.3.D
    rotationBlobCodec: rotationBlobCodec             // reuse from 5.3.D
)
let rotationFetchScheduler = RotationFetchScheduler(
    fetchService: rotationFetchService,
    keyRotationService: keyRotationService,
    intervalSec: agentThresholds.rotationFetchIntervalSec,
    logger: agentLogger
)
AgentLifetime.rotationFetchScheduler = rotationFetchScheduler

// Existing `Task.detached { resumePendingPosts() }` block (line 250-259)
// REMAINS — fast first-launch resume before scheduler's first tick.

// Start scheduler:
Task { await rotationFetchScheduler.start() }

// Shutdown chain (line 282-293) — prepend rotationFetchScheduler stop:
installSignalHandlers {
    if let r = AgentLifetime.rotationFetchScheduler { await r.stop() }   // NEW
    if let m = AgentLifetime.maintenance { await m.stop() }
    // ...
}
```

`AgentLifetime` enum (line 306-316) +1 slot:
```swift
nonisolated(unsafe) static var rotationFetchScheduler: RotationFetchScheduler?
```

---

## 11. Tests

### 11.1 Public SPM (`Tests/LeafCoreTests/`)

`RotationFetchOutcomeTests.swift` (~3 cases):
1. Equatable + Hashable round-trip.
2. `.empty` static value verifies all-zero.
3. Distinct value combos hash-distinct.

`DatabaseInsertTeamKeyIfAbsentTests.swift` (~4 cases):
1. `_HappyPath_InsertsRow` — fresh DB → row visible.
2. `_DuplicateID_NoOpPreservesFirstRow` — insert twice → only first persists; second → no-op.
3. `_ReaderModeThrowsDatabaseUnavailable`.
4. `_AfterInsertReadActiveReturnsRow` — sanity that ON CONFLICT path doesn't break partial-index `team_keys_active`.

`RotationFetchServiceTests.swift` (~12-15 cases): URLProtocol stub + recording RotationKDF/Codec. Fixture (`insertTeamFixture`):
- org + 3 active members (admin self / admin2 / member3) + initial active teamKey + keystore seeded.
1. `_TombstoneHappyPath_MarksSelfRemoved` — relay returns tombstone for self → markTeamMemberRemoved called → fetch outcome `.tombstoneApplied=1, fetched=1`.
2. `_TombstoneHappyPath_AcksRelay` — tombstone path also ACKs.
3. `_TombstoneMisroutedToOtherMember_DoesNotMarkSelf` — tombstone with `removedMemberID != self_member_id` → skip + no ack.
4. `_TombstoneMissingPriorTeamKeyInKeystore_Skips` — keystore deleted → readTeamKey throws → skip + no ack.
5. `_RotationHappyPathSingleAdmin_Installs` — relay returns rotation from sole admin → `insertTeamKeyIfAbsent + deprecateTeamKey + writeTeamKey` → outcome `.installed=1`.
6. `_RotationHappyPathMultiAdmin_FirstWorks_DoesNotTrySecond` — two admins, first ECDH works → second iteration skipped (verify recording-ECDH-derive count == 1).
7. `_RotationHappyPathMultiAdmin_FirstFails_SecondWorks` — first wrapKey wrong, second works → installed.
8. `_RotationAllAdminsFail_NoInstall_NoAck` — wrapKey from all admins fails → outcome `.skipped=1, installed=0`. ACK not called.
9. `_RotationDuplicateInstall_Idempotent` — call tick twice with same blob → second call's insertTeamKeyIfAbsent no-op (still installs=1 because we run install path). Verify only one team_keys row in DB.
10. `_PeekFails_Skips_NoAck` — short blob → outcome `.skipped=1, fetched=1`.
11. `_RelayFetchTransportError_ReturnsEmpty` — URLProtocol throws → outcome `.empty`.
12. `_NoOrg_ReturnsEmpty` — DB without org → no relay call.
13. `_EmptyMailbox_ReturnsEmpty_NoAck` — relay 200 empty array → outcome `.empty`.
14. `_MultipleBlobs_MixedOutcomes` — relay returns 3 blobs (1 happy rotation, 1 happy tombstone, 1 corrupt) → counts {fetched:3, installed:1, tombstoneApplied:1, skipped:1}.

`RotationFetchSchedulerTests.swift` (~3 cases):
1. `_StartTickStop` — start → wait 0.1s → tick observed (recording fetchService captures call) → stop → no further tick.
2. `_TickCallsBothServices` — single performTick → recording fetch + recording resume both called.
3. `_CancelDuringSleep_StopsCleanly` — start with 100s interval → stop within 50ms → returns promptly (cancel respected).

**SPM Δ:** ~22-25 new cases.

### 11.2 Moat E2E (`Tests/LeafCorePrivateTests/`, gitignored)

Extend `RotationHandshakeIntegrationTests.swift` (5.3.D) with 1-2 cases using **real** `ProdRotationKDF` + `ProdRotationBlobCodec` + `RotationFetchService` end-to-end:

1. `testEndToEndHandshake_AdminPostsThenPeerInstalls` —
   - Setup admin Mac DB (in-memory) + peer Mac DB + keystores + identities.
   - Admin's `KeyRotationService.removeMember(thirdParty)` → URLProtocol captures POSTs.
   - Replay POST bodies as relay GET responses for peer's pubkey.
   - Peer's `RotationFetchService.tick()` → assert insertTeamKeyIfAbsent installed admin's newKeyID; teamKey bytes byte-for-byte match admin's; deprecateTeamKey'ed prior; ackRotation called.
2. (optional) `testEndToEndHandshake_TombstonePeerSelfRemoved` —
   - Same setup, but admin removes peer (the same one running RotationFetchService).
   - Peer's tick → `markTeamMemberRemoved(self)` happens → `OrgReader.refresh` → state `.removedFromOrg`.

**Moat Δ:** +1-2 cases.

### 11.3 Leaf target manual test (no SPM coverage)

`MemberRemovalReader` / `RemoveMemberSheet` / `RemovedFromTeamBanner` / `TeamView.memberRow` — testable only via Xcode Run + manual UI smoke (Stage 7 ship-gate two-Mac test). SPM tests cover service layer; UI is thin.

### 11.4 Total Δ

835 SPM (этой машине) + ~25 = ~860. Cross-machine canonical Дмитрия (с moat) ~895-940.

---

## 12. Threat model + invariants

### 12.1 Capability model (unchanged from 5.3.B/C/D)

Relay = honest-but-curious. Mailbox keyed by peer pubkey (bearer). Blob is AES-GCM-256 ciphertext под либо ECDH+HKDF wrapKey либо raw prior teamKey wrapKey. Even leaked pubkey yields opaque bytes only.

### 12.2 Tombstone forgeability (acknowledged 5.3.B AD #6)

Any current team member can forge a tombstone targeting another peer (wrapKey = shared prior teamKey). Mitigated cross-field invariant: `removedMemberID` must reference *self* (peer-side check post-decrypt, §5.3 step 6). Forged tombstone targeting another peer → fails self-check → skip + no-ack. Self-forgery is moot (peer can't forge an instruction to themselves they wouldn't accept).

### 12.3 Mis-routed blob protection

Relay routes by `peer_pubkey_hex` URL param; peer always fetches from own URL. Mis-routing requires admin-side bug. Defensive cross-check: tombstone path verifies `plaintext.removedMemberID` matches local self-member-id; rotation path verifies `plaintext.kind == .rotation` post-decrypt.

### 12.4 Replay protection

Relay composite-key dedup на `(peer, new_key_id)` ensures admin's retry posts same `rotation_id` (idempotent). Peer's repeated install is idempotent via `insertTeamKeyIfAbsent` + `markTeamMemberRemoved` silent-on-already-removed.

### 12.5 Session integrity

`RotationFetchService` has no in-memory state across ticks — each tick is independent. Crash mid-tick → next launch picks up un-acked blobs; install path is idempotent.

### 12.6 Orphan keystore protection

Keystore-first ordering (§5.4 step 4c → 4d): if `insertTeamKeyIfAbsent` succeeds but `deprecateTeamKey` throws (e.g., prior already deprecated by re-fetch race) — keystore file persists, DB has both keys (or new key inserted, prior already deprecated from earlier tick). State is consistent. If keystore write succeeds but `insertTeamKeyIfAbsent` throws (rare DB error) — orphan keystore file persists; subsequent successful install re-uses it; or stays as harmless orphan (mirror 5.1.D pattern).

---

## 13. Error semantics

| Error source | Where surfaced | Caller behaviour |
|---|---|---|
| `RotationBlobHeader.peek` throws (`.rotationBlobMalformed`) | RotationFetchService | skip + no ack |
| `TeamKeystore.readTeamKey` throws (`.keyFileUnavailable` / `.keyFileCorrupted`) | RotationFetchService tombstone path | skip + no ack; log |
| `RotationBlobCodec.decode` throws (AES-GCM tag fail / JSON / cross-field) | RotationFetchService rotation path | continue iterating admins; if exhausted → skip + no ack |
| `KeyAgreement.sharedSecret` throws (bad hex / decode pubkey) | RotationFetchService rotation path | continue iterating admins (defensive — pubkey validated at insertTeamMember; should never trigger в normal flow) |
| `Database.insertTeamKeyIfAbsent` throws | RotationFetchService install path | skip + log (orphan keystore acceptable) |
| `Database.deprecateTeamKey` throws (`.invalidPayload`) | RotationFetchService install path | skip + log (could happen if priorKeyID не in local team_keys — admin/peer DB out of sync; recovery via fresh re-invite) |
| `Database.markTeamMemberRemoved` throws | RotationFetchService tombstone path | log; tombstone path still considers applied (idempotent) |
| `relayClient.fetchPendingRotations` throws | RotationFetchService preflight | return `.empty` (silent — next tick retries) |
| `relayClient.ackRotation` throws | RotationFetchService post-install | swallow (relay TTL eventually purges; no replay risk because install is idempotent) |
| `KeyRotationService.removeMember` throws | MemberRemovalReader | surface user-facing message |
| `KeyRotationService.resumePendingPosts` throws | RotationFetchScheduler | log non-fatal |

---

## 14. Acceptance

### 14.1 Per-stage

- `swift test --package-path Packages/LeafCore` — все pass; numerical Δ matches plan (~+22-25 cases on этой машине).
- `xcodebuild -scheme Leaf` / `LeafAgent` / `LeafMCP` / `LeafCore` / `LeafCorePrivate` — все BUILD SUCCEEDED.
- Independent code review (`superpowers:code-reviewer`) — APPROVED (or NEEDS-CHANGES → addressed → APPROVED).

### 14.2 Manual ship-gate (two-Mac smoke — Алекс)

1. Mac A admin creates org `"Smoke A"`. Mac A's TeamView shows 1 member (self admin).
2. Mac A clicks "Add member" → generates invite → copies token + OTP.
3. Mac B (clean DB) accepts invite → sees Joined `"Smoke A"`. Mac B's TeamView shows 2 members.
4. Mac A's TeamView shows 2 members — self + Mac B.
5. On Mac A: hover Mac B's row → click "..." → "Remove from team…" → confirm.
6. Mac A sees `"Removed Mac B" "1 of 1 peer notified"`. Click Done. TeamView shows 1 member (self).
7. Wait <60s on Mac B (Agent's RotationFetchScheduler tick).
8. Open Mac B's app. RootView shows `"You've been removed from Smoke A"` banner.
9. Inspect Mac A's `events.sqlite`: `SELECT * FROM team_keys` shows 2 rows (1 active new, 1 deprecated prior). `SELECT * FROM team_members` shows Mac B with `removed_at_ms` set.
10. Inspect Mac B's `events.sqlite`: `SELECT * FROM team_members` shows Mac B (self) with `removed_at_ms` set. Local `team_keys` rows still present (forever-retention).

Pass criteria — all 10 steps observable. Failure criteria — banner doesn't surface within 90s on Mac B / Mac A's TeamView still shows Mac B / DB state mismatch.

### 14.3 Post-stack ship-gate

5.3.E landing finalizes Phase 5.3 stack. After 5.3.E lands (with successful manual smoke), single merge of `feature/phase-5-3-A` → `main` (no-ff merge preserving 5.3.A→B→C→D→E history). Pattern matches 5.1.A-E and 5.2.A-E ship discipline. Followed by alpha.X release per 4.7+ ship pattern (single merge → version bump → release.sh → notarize → R2 → Sparkle).

---

## 15. Out of scope

| Excluded | Reserved for |
|---|---|
| WS broadcast loop / `ProdEnvelopeCodec` first real consumer | Phase 5.4 |
| Onboarding screen 6 final integration | Phase 5.5 |
| Wipe local team data action в RemovedFromTeamBanner | Post-MVP via Settings sweep |
| Privacy Dashboard surface для skipped fetches | Post-MVP |
| Multi-admin rotation race confirmation dialog | UI-level concern post-MVP |
| Sole-admin lockout invariant on UI | Post-MVP (service permits multi-admin) |
| Rate limiting на admin spam | Post-MVP |
| Inter-process notification (Agent → main app) for fast banner | Phase 5.4 (presence channel может piggy-back) |
| Proactive rotation API (`rotate()` без removal) | v1.1 per 5.3.D §11 |
| MCPServer surface для removedFromOrg | Post-MVP |
| MenuBarExtra removedFromOrg surfacing | Phase 5.4+ |

---

## 16. Whitepaper sync

**NONE** during 5.3.E.

`presence-relay.md` уже описывает rotation flow абстрактно. Service-layer / scheduler / UI layer — implementation detail, не уходит в public docs.

`storage.md` — table list уже отражает `team_keys` / `team_members` / `rotation_outbox` since 5.1.A / 5.3.D respectively. No new tables.

`changelog.md` — single Phase 5.3 ship'у в alpha.X covers 5.1+5.2+5.3 stacks (mirror 5.1.A-E + 5.2.A-E ship discipline). Не fragmented per sub-phase.

---

## 17. Forward dependencies

### Phase 5.4 will use

- `OrgReader.removedFromOrg` flag — presence broadcast loop should refuse to broadcast if state == `.removedFromOrg`. Hookup в 5.4.
- `RotationFetchScheduler` — could be extended to tick presence WS reconnect.
- `team_keys` history retention (5.1.B / 5.3.A `readTeamKey(byID:)`) — `ProdEnvelopeCodec` decoder consults this for incoming `keyID` lookup. Already in place since 5.3.A.

### Phase 5.5 will use

- `OrgReader.refresh` exposed semantic (RootView `.onAppear` trigger) — Onboarding final integration may pre-trigger refresh after team join.

### No 5.3 Forward consumers

5.3 stack closed end-to-end. No further sub-phases.

---

## 18. Risks / open questions

| # | Risk | Mitigation |
|---|---|---|
| R1 | Multi-admin race (admin1 + admin2 concurrent removeMember; 5.3.D R2) — peer might iterate admins in arbitrary order, succeeding on either; if both blobs delivered, second consumed at relay (composite-key dedup) means peer only ever sees one anyway. | Acceptable — relay first-writer-wins on `(peer, new_key_id)` composite. Iteration order for admin candidates: `readTeamMembers` ordered by `added_at_ms ASC` — deterministic but not load-balanced. No correctness risk. |
| R2 | `RotationFetchScheduler` interval 60s default may feel slow for "you've been removed" UX (up to 60s wait between tick and banner). | Acceptable for MVP — member removal is rare; user не observably affected if app closed; .onAppear refresh shortens latency on app reopen. Phase 5.4 presence channel piggy-backs faster signal. |
| R3 | `RotationFetchService` admin candidate iteration with empty admin list (peer's local team_members has no `.admin` role except self) — could happen on edge case where founder is sole admin and somehow self is being rotated TO. Defensive: rotation path returns false (skipped). | Tombstone path unaffected (uses prior teamKey). Edge case rare in practice — sole admin can't rotate themselves out (KeyRotationService.cannotRemoveSelfFromTeam preflight). |
| R4 | `OrgReader.refresh` IdentityService call slow на cold cache (first identity creation involves SecureRandom + atomic write). | IdentityService idempotent + cached at file system; second call <1ms. Benchmarked in Phase 5.2.A. Negligible. |
| R5 | UI race: user clicks "..." menu while `OrgReader.state` transitioning to `.removedFromOrg` (admin removed self via second admin while user opens TeamView). | TeamView checks `reader.state` — if `.removedFromOrg`, RootView shows banner instead of TeamView. Sheet won't open. |
| R6 | `MemberRemovalReader` instantiates own writer DB — concurrent writes between Agent (RotationFetchScheduler) и main app (MemberRemovalReader). | SQLite WAL serializes writers via cross-process POSIX locks (architecture.md ADR-017 confirmed pattern). Agent's `writeEventsOffsetAndPresence` + main app's `commitRotation` lock-coordinated. Acceptable. |
| R7 | `RemovedFromTeamBanner` doesn't account для tombstone arriving while user is mid-action (e.g., just opened "..." menu). Sheet would be dismissed by RootView swap. | Acceptable — sheet swap is non-destructive; user re-opens app, sees banner. |
| R8 | `RotationFetchScheduler.performTick` swallows `KeyRotationService.resumePendingPosts` errors. If outbox is corrupt (e.g., bad JSON), errors silently. | Mirror existing `Task.detached` resume on Agent boot (5.3.D) which also swallows. Diagnostic surface = post-MVP per R1 5.3.D. |

---

## 19. Pre-push checklist (`gundemtech/leaf` is public)

Before `git push origin feature/phase-5-3-E`:
- ❌ NO public diff exposes any moat constants from 5.3.B (HKDF info string, AAD layout) — все references abstract via `RotationKDF` / `RotationBlobCodec` protocols.
- ❌ NO public diff exposes byte offsets от RotationBlobHeader (already in `LeafCorePrivate`).
- ❌ NO leak relay KV key prefix scheme (5.3.C moat).
- ❌ NO leak `agentThresholds.rotationFetchIntervalSec` precise prod-value беyond default 60 (which is documented as "aligns with presence WS heartbeat in 5.4 contract" — already public via architecture.md). Prod copy в `LeafCorePrivate` (gitignored) may carry different value if needed; default doc-string remains generic.
- ✅ Public surface: service public API shapes, factory injection patterns, error types, atomic-tx contract, scheduler lifecycle, UI state machine.
- ✅ Test assertions cover *shape* (DB rows present/absent, outcome counts, error types), не secret values.

`/pre-push-leaf` MUST pass before push.

---

## 20. Commit decomposition (target ~16-18 commits)

1. `docs(specs): Phase 5.3.E — peer fetch + UI spec` — this file.
2. `feat(core): Phase 5.3.E — Database.insertTeamKeyIfAbsent` + 4 tests.
3. `feat(core): Phase 5.3.E — RotationFetchOutcome value type` + 3 tests.
4. `feat(core): Phase 5.3.E — RotationFetchService scaffold + init`.
5. `feat(core): Phase 5.3.E — RotationFetchService.tick (preflight + drain)` + 3 tests.
6. `feat(core): Phase 5.3.E — RotationFetchService tombstone path` + 4 tests.
7. `feat(core): Phase 5.3.E — RotationFetchService rotation path (admin iteration + install)` + 5 tests.
8. `feat(core): Phase 5.3.E — RotationFetchScheduler` + 3 tests.
9. `feat(core): Phase 5.3.E — agentThresholds.rotationFetchIntervalSec`.
10. `feat(core/private): Phase 5.3.E — Rotation handshake E2E peer install (gitignored moat)` + 1-2 tests.
11. `feat(app): Phase 5.3.E — OrgReader.removedFromOrg state + self-pubkey lookup` + manual test reasoning.
12. `feat(app): Phase 5.3.E — MemberRemovalReader Observable`.
13. `feat(app): Phase 5.3.E — RemoveMemberSheet view`.
14. `feat(app): Phase 5.3.E — RemovedFromTeamBanner view`.
15. `feat(app): Phase 5.3.E — TeamView per-row Menu trigger + showingRemoveSheet wiring`.
16. `feat(app): Phase 5.3.E — RootView removedFromOrg branch + LeafApp env wiring`.
17. `feat(agent): Phase 5.3.E — Agent.swift composition root + AgentLifetime slot + shutdown chain`.
18. `docs(shared): Phase 5.3.E landed — Phase 5.3 stack closed — current-state update`.

---

*End of spec. Plan уровня commit-by-commit — следом, через `superpowers:writing-plans` skill.*
