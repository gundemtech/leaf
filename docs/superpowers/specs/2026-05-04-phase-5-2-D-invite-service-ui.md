# Phase 5.2.D — `RelayClient` + `InviteService` + Generate-invite UI

**Status:** Active (2026-05-05). Fourth sub-phase of Phase 5.2 ("relay invite endpoints + invite UX + ECDH handshake").
**Owner:** Dmitrii.
**Stack:** branches off `feature/phase-5-2-C` (linear A→B→C→D — 5.2.C docs commits noop для кода). Implementation lives entirely в `gundemtech/leaf` repo; depends on 5.2.C deploy live на `oauth.gundem.tech/v1/invite/*` к моменту E2E gate (manual UI smoke).

---

## 1. Context

Phase 5.2.A (commits `2862914..705e3d0`) landed identity primitives — `IdentityService.ensureLocalIdentity`, `KeyAgreement.sharedSecret`, `InviteKDF` protocol + moat HKDF impl.
Phase 5.2.B (commits `..a95a700`) landed envelope primitives — `InvitePlaintext`, `InviteBlob` + `InviteBlobHeader.peek`, `InviteBlobCodec` protocol + moat AES-GCM impl.
Phase 5.2.C (commits `3ab1590..f068c56`) landed leaf-relay wire layer specs — POST/GET/DELETE `/v1/invite/*` + INVITES KV — implementation deploys в `gundemtech/leaf-relay` separately.

5.2.A/B/C — substrate без consumer'а. **5.2.D даёт первого real consumer'а на admin-side:** admin берёт invitee X25519 pubkey OOB → wrap'ит teamKey + org metadata в opaque blob → POST на relay → получает token+OTP → отдаёт invitee OOB.

Это **первый call-site** для `ProdInviteKDF` и `ProdInviteBlobCodec` через composition root. Mirror precedent 5.1.C → 5.1.D: substrate-only фазы (5.2.A/B) не wire'ят prod impl; первая фаза-consumer (5.2.D) wire'ит.

5.2.E (invitee accept-flow + Onboarding screen 6 partial + E2E URLProtocol-stub integration test) идёт следом stack'ом — закрывает full handshake.

**Источники правды (priority при противоречии):**

1. `2026-05-04-phase-5-architecture-contract.md` — §5 (trust model: relay sees opaque blobs only), §6 (envelope), §7 (key lifecycle), §8 (relay API surface), §10 (failure modes).
2. `2026-05-04-phase-5-2-decomposition.md` — §3 (sub-phase scope locked), §4.1 (file layout), §4.5 (`RelayClient` Swift signature locked), §4.6 (LeafError additions), §7 (out-of-scope), §8 (risks).
3. `2026-05-04-phase-5-2-A-identity-kdf.md`, `2026-05-04-phase-5-2-B-invite-blob.md`, `2026-05-04-phase-5-2-C-relay-invite.md` — sister-phase contracts.
4. `~/Desktop/Leaf/leaf-docs/docs/03-architecture/presence-relay.md` — public-truth invite flow (24h token, 6-digit OTP, OOB transmission, X25519 ECDH, HKDF-SHA256 with OTP salt).
5. Existing patterns в `leaf` — `OrgService` factory injection (5.1.D), `OrgReader` Observable lazy-init (5.1.E), `SlackTokenRefresher` URLSession injection (4.4), `GitHubOAuthService` state machine (4.3).

---

## 2. Decisions taken (post-brainstorm 2026-05-05)

| # | Decision | Rationale |
|---|---|---|
| D1 | **Branch off feature/phase-5-2-C** (linear A→B→C→D) | Mirror 5.1.x stack discipline. 5.2.C docs commits noop для кода — не блокируют. |
| D2 | **`InviteOutboxReader` — in-memory ephemeral** (last-generated invite only) | Per decomposition §7 "minimal version в 5.2.D if cheap". Никаких new tables / migrations / DB writes. Закрыл sheet — потерял token+OTP (но invite живёт в KV до consume/expire — admin может revoke через DELETE если remembered token, иначе wait 24h). Outstanding-invite list + revoke UI deferred → 5.5+. |
| D3 | **Invitee pubkey: paste hex в TextField** sheet'а | Whitepaper OOB philosophy. Validation = 64 hex chars (lower/upper accepted, mirrors `KeyAgreement.decodePublicKey(hex:)` lenient decode). QR/deep-link deferred → future. |
| D4 | **"+ Add member" CTA в TeamView для всех** | В MVP single-org-per-device + admin-of-own-org → CTA всегда показан в `.loaded` state. Future: hide для non-admin members когда invitee accept-flow добавит non-admin members в DB (5.2.E). |
| D5 | **OTP genesis — factory injection** | Inject `randomOTP: @Sendable () throws -> String` в `InviteService.init` (default = `InviteService.secureRandomOTP` использует `SystemRandomNumberGenerator`); deterministic в tests. Format `String(format: "%06d", n)` где `n = Int.random(in: 0..<1_000_000)` — exactly 6 ASCII digits per `InviteKDF` contract. |
| D6 | **`expiresAtMs = now + 24h`** hardcoded в `InviteService` | Server validates `now ≤ x ≤ now+24h+60s skew` (relay 5.2.C §5 row 9); client sends `now+24h` exactly — внутри допустимого окна. |
| D7 | **`RelayClient` — actor с inject'абельным URLSession** | Spec §4.5 заlock'ил `public actor RelayClient`. URLSession injection mirror `SlackTokenRefresher` (4.4) для URLProtocol stub в tests. |
| D8 | **Composition root для `ProdInviteKDF` + `ProdInviteBlobCodec` — `LeafApp.swift`** (не `Agent.swift`) | Invite-генерация — admin **UI flow в MenuBarApp target**, не daemon-side. Mirror 5.1.D `OrgService` injection (LeafApp owns OrgReader → OrgService prod factory). Agent.swift unchanged. |
| D9 | **Wire encoding boundary в `RelayClient`, не в `InviteBlob` value type** | `InviteBlob.bytes: Data` остаётся domain-pure (5.2.B §4.2). `RelayClient.postInvite` base64url-encodes на отправку; `RelayClient.getInvite` base64url-decodes на receive. Per decomposition §4.5 `RelayClient` accepts `blob: Data` parameter — value type не leak'ит wire concerns. |
| D10 | **`InviteOutbound` value type** (не `(token, otp, expiresAt)` tuple) | LeafCore-level Sendable struct: `token / otp / expiresAtMs / inviteePubkeyHex` (для UI back-reference "this is for invitee X"). Hashable для use в sheet state. |

---

## 3. Scope

### Входит

| Артефакт | Файл | Заметка |
|---|---|---|
| `RelayClient` actor + `InviteToken` + `InviteFetched` value types | `Packages/LeafCore/Sources/LeafCore/Relay/RelayClient.swift` (новый, новая директория `Relay/`) | URLSession-based, JSON encode/decode, status→error mapping per relay 5.2.C wire format §4 |
| `InviteOutbound` value type | `Packages/LeafCore/Sources/LeafCore/Team/InviteOutbound.swift` (новый) | Sendable, Hashable: `token / otp / expiresAtMs / inviteePubkeyHex` |
| `InviteService` admin orchestrator | `Packages/LeafCore/Sources/LeafCore/Team/InviteService.swift` (новый) | Reads org/admin member/active teamKey/X25519 priv → builds plaintext → calls KDF + codec + relay → returns `InviteOutbound` |
| `LeafError` +3 cases | `Packages/LeafCore/Sources/LeafCore/LeafError.swift` (edit) | `relayUnreachable(reason: String)`, `inviteNotFound`, `inviteRequestRejected(reason: String)` per decomposition §4.6 |
| LeafCore unit tests | `Tests/LeafCoreTests/{RelayClientTests,InviteServiceTests,InviteOutboundTests}.swift` | ≈25 public tests — URLProtocol stub harness; InviteService использует mock RelayClient + recording KDF/Codec doubles |
| LeafCorePrivate moat tests | `Tests/LeafCorePrivateTests/InviteHandshakeIntegrationTests.swift` | ≈5 moat tests: real `ProdInviteKDF` + `ProdInviteBlobCodec` round-trip через mock RelayClient (admin-side только; invitee unwrap → 5.2.E) |
| `InviteOutboxReader` Observable | `Leaf/Models/InviteOutboxReader.swift` (новый) | `@MainActor @Observable`. State `.idle / .generating / .ready(InviteOutbound) / .error(message:)`. Dispatches `InviteService.generateInvite(...)` Task; lazy-init `InviteService` в `ensureService()` mirror `OrgReader.ensureDatabase()` |
| `GenerateInviteSheet` view | `Leaf/Views/Window/Team/GenerateInviteSheet.swift` (новый) | TextField для invitee pubkey hex + GlassCard form + Generate button (disabled-while-generating) + result panel (token/OTP с copy buttons + countdown) + Discard + Revoke buttons |
| `TeamView` — "+ Add member" CTA | `Leaf/Views/Window/Team/TeamView.swift` (edit) | Button под `membersList` в `.loaded` branch → presents `GenerateInviteSheet` через `.sheet(isPresented:)` |
| `LeafApp` wiring | `Leaf/LeafApp.swift` (edit) | `@State var inviteOutboxReader = InviteOutboxReader()`; `.environment(inviteOutboxReader)` для main Window scene. Composition root `#if LEAF_PROD` guards inject `ProdInviteKDF()` + `ProdInviteBlobCodec()`; `#else` `UnimplementedInviteKDF()` + `UnimplementedInviteBlobCodec()` |

### НЕ входит (явно отложено)

- **Invitee accept-flow** (`InviteAcceptService`, `InviteAcceptReader`, accept sheet, Onboarding screen 6 partial) — **5.2.E**.
- **E2E integration test** через URLProtocol stub (admin generate → invitee accept full handshake) — **5.2.E** (5.2.D moat test покрывает admin-side только).
- **Outstanding-invite list UI** + admin "View all my pending invites" / per-invite revoke list — **5.5+** (5.2.D даёт `RelayClient.deleteInvite` API + per-sheet Revoke button only).
- **KV-propagation latency hint в UI** ("invite ready in ~30s") — **5.2.E** (вместе с invitee retry-on-404 logic).
- **Onboarding screen 6** any version — **5.2.E**.
- **`presence_outgoing` / `presence_history` + WS broadcast** — **5.4**.
- **Member removal / key rotation** — **5.3**.
- **Whitepaper sync** — `presence-relay.md` уже описывает invite flow абстрактно. Public-truth update timed at 5.2.E ship (end-of-track).

---

## 4. Public surface

### 4.1 `RelayClient` (signature locked в decomposition §4.5)

```swift
public actor RelayClient: Sendable {
    public init(baseURL: URL = URL(string: "https://oauth.gundem.tech")!,
                urlSession: URLSession = .shared)

    public func postInvite(memberPubkeyHex: String,
                           blob: Data,
                           expiresAtMs: Int64) async throws -> InviteToken
    public func getInvite(token: String) async throws -> InviteFetched
    public func deleteInvite(token: String) async throws
}

public struct InviteToken: Sendable, Hashable {
    public let value: String
    public let expiresAtMs: Int64
}

public struct InviteFetched: Sendable {
    public let blob: Data
    public let expiresAtMs: Int64
}
```

**Status → `LeafError` mapping** (per relay 5.2.C wire format §4):

| HTTP | Mapping |
|---|---|
| 201 (POST) | success → `InviteToken` (parsed from JSON body `{token, expires_at_ms}`) |
| 200 (GET) | success → `InviteFetched` (decode `blob` base64url) |
| 204 (DELETE) | success |
| 400 | `LeafError.inviteRequestRejected(reason: "bad-input")` |
| 404 (GET) | `LeafError.inviteNotFound` |
| 405 | `LeafError.inviteRequestRejected(reason: "method")` |
| 413 | `LeafError.inviteRequestRejected(reason: "size")` |
| 415 | `LeafError.inviteRequestRejected(reason: "media-type")` |
| 500 | `LeafError.relayUnreachable(reason: "server-error")` |
| URLSession network throw | `LeafError.relayUnreachable(reason: "transport")` |
| Unparseable body / unexpected status | `LeafError.relayUnreachable(reason: "malformed-response")` |

`reason` strings — generic ("bad-input", "method", "size", "media-type", "server-error", "transport", "malformed-response"). Не embed server's exact validation labels (e.g. `400 invite-bad-pubkey`) — leak-safe per `/pre-push-leaf`.

### 4.2 `InviteService`

```swift
public struct InviteService: Sendable {
    public init(database: Database,
                relayClient: RelayClient,
                inviteKDF: any InviteKDF,
                inviteBlobCodec: any InviteBlobCodec,
                keystoreRoot: URL = TeamKeystore.defaultRoot(),
                now: @escaping @Sendable () -> Date = { Date() },
                randomOTP: @escaping @Sendable () throws -> String = InviteService.secureRandomOTP,
                identity: (@Sendable () throws -> Curve25519.KeyAgreement.PrivateKey)? = nil)

    /// Admin-side: build invite blob, POST to relay, return token+OTP for OOB transmission.
    /// - Parameter inviteePubkeyHex: 64-char X25519 public, OOB-received from invitee.
    /// - Throws: `LeafError.invalidPayload` (bad hex), `.databaseUnavailable` (no org / no active team key),
    ///           `.keyFileUnavailable` (keystore broken), `.relayUnreachable`, `.inviteRequestRejected`.
    public func generateInvite(inviteePubkeyHex: String) async throws -> InviteOutbound

    /// Admin-side revoke: best-effort DELETE on relay. Idempotent (relay returns 204 always per §4.3).
    public func revokeInvite(token: String) async throws

    public static func secureRandomOTP() throws -> String  // 6 ASCII digits
}

public struct InviteOutbound: Sendable, Hashable {
    public let token: String              // 32 base64url chars from relay
    public let otp: String                // 6 ASCII digits
    public let expiresAtMs: Int64
    public let inviteePubkeyHex: String   // for UI back-reference
}
```

**`generateInvite` flow:**

1. Validate `inviteePubkeyHex.count == 64` matches `^[0-9a-fA-F]{64}$` (else `.invalidPayload`).
2. Read `org` from DB via `database.readOrg()` (else `.databaseUnavailable` — UX слой surfaces "create personal org first").
3. Read self admin member: `database.readTeamMembers(orgID: org.id, includeRemoved: false).first` (single-org-per-device + first inserted = self admin per 5.1.D `OrgService`; LIMIT-1-equivalent defensive).
4. Read active team key meta: `database.readActiveTeamKey()` (else `.databaseUnavailable`); read team key bytes via `TeamKeystore.readTeamKey(id: activeKey.id, at: keystoreRoot)`.
5. Read X25519 priv via `IdentityService.ensureLocalIdentity(at: keystoreRoot)` (idempotent; reuses existing).
6. Generate OTP via `randomOTP()`.
7. Compute shared secret: `KeyAgreement.sharedSecret(privateKey: adminPriv, peerPublicKeyHex: inviteePubkeyHex)`.
8. Derive wrap key: `inviteKDF.deriveWrapKey(sharedSecret:, otp:)`.
9. Build `InvitePlaintext`:
   - `teamKeyBase64` = base64-encoded raw 32B from keystore.
   - `teamKeyID` = `activeKey.id`.
   - `orgID` = `org.id`, `orgName` = `org.name`.
   - `adminMemberID` = `selfMember.id`, `adminDisplayName` = `selfMember.displayName`.
   - `issuedAtMs` = `Int64(now().timeIntervalSince1970 * 1000)`.
10. Encode blob: `inviteBlobCodec.encode(plaintext, adminPubkey: adminPriv.publicKey.rawRepresentation, wrapKey:)`.
11. `expiresAtMs = Int64(now().timeIntervalSince1970 * 1000) + 24*60*60*1000`.
12. `let invite = try await relayClient.postInvite(memberPubkeyHex: inviteePubkeyHex.lowercased(), blob: blob.bytes, expiresAtMs:)`.
13. Return `InviteOutbound(token: invite.value, otp:, expiresAtMs:, inviteePubkeyHex:)`.

Errors propagate прозрачно — нет catch-all rewriting. UI слой (`InviteOutboxReader`) maps `LeafError` → user-facing message.

### 4.3 `LeafError` additions

```swift
case relayUnreachable(reason: String)         // network / 500 / malformed body
case inviteNotFound                           // 404 on GET (5.2.E consumer; added в 5.2.D RelayClient mapping)
case inviteRequestRejected(reason: String)    // 400 / 405 / 413 / 415
```

`inviteNotFound` сейчас никем не throws со стороны admin generate — case добавлен заранее ради 5.2.E `InviteAcceptService` (single LeafError-touching commit; consumer wires в 5.2.E).

---

## 5. UI surface

### 5.1 `GenerateInviteSheet`

Layout sketch (final styling tuned in implementation, не контракт):

```
┌─ Generate invite ───────────────────────────────────┐
│                                                      │
│  Step 1 · Invitee shares their pubkey with you      │
│  ┌──────────────────────────────────────────────┐   │
│  │  Pubkey hex (64 characters)                  │   │
│  │  [                                          ]│   │
│  └──────────────────────────────────────────────┘   │
│  [ Generate invite ]                                 │
│                                                      │
│  ── after Generate ──                                │
│                                                      │
│  Step 2 · Send to invitee (Slack/Telegram)          │
│  ┌──────────────────────────────────────────────┐   │
│  │  TOKEN                              [ Copy ] │   │
│  │  abc...32chars                               │   │
│  │  OTP                                [ Copy ] │   │
│  │  1 2 3 · 4 5 6                               │   │
│  │  Expires in 23h 59m                          │   │
│  └──────────────────────────────────────────────┘   │
│                                                      │
│  [ Discard ]                       [ Revoke + Done ] │
└──────────────────────────────────────────────────────┘
```

States via `InviteOutboxReader.state`:
- `.idle` — Step 1 visible only; Generate enabled iff input valid (64 hex).
- `.generating` — Generate button shows progress; input disabled.
- `.ready(InviteOutbound)` — Step 2 visible с copy buttons; expires countdown derived (`expiresAtMs - now`).
- `.error(message:)` — inline red text под Step 1; Generate re-enabled to retry.

Discard — `.dismiss()` sheet, leaves invite в KV (admin can revoke later if remembered token, или wait 24h expiry).
Revoke + Done — calls `InviteService.revokeInvite(token:)` через reader, dismisses on completion. Errors logged + dismissed anyway (best-effort per relay §4.3 idempotent DELETE).
Copy buttons — `NSPasteboard.general.setString(...)` (sandbox OFF per architecture контракт; pasteboard доступен).

### 5.2 `TeamView` edit

`+ Add member` button под `membersList(members)` в `.loaded` branch. `.sheet(isPresented: $showingGenerateSheet)` mounts `GenerateInviteSheet`. Styled `.borderedProminent`, mirrors Organization tab `Create personal org` CTA.

### 5.3 `InviteOutboxReader` (UI Observable)

```swift
@MainActor @Observable
final class InviteOutboxReader {
    enum State: Equatable {
        case idle
        case generating
        case ready(InviteOutbound)
        case error(message: String)
    }

    private(set) var state: State = .idle
    private var service: InviteService?

    func generate(inviteePubkeyHex: String)  // dispatches Task
    func revokeAndDismiss()                  // best-effort DELETE then resets to .idle
    func dismiss()                           // resets to .idle without DELETE
}
```

Lazy-init pattern mirrors `OrgReader.ensureDatabase()`:
- `ensureService()` — opens DB + constructs `RelayClient` + `InviteService` on first generate call.
- Static factories `defaultInviteKDF()` / `defaultInviteBlobCodec()` — `#if LEAF_PROD` switch (see §6).

---

## 6. Composition root (LeafApp.swift)

```swift
nonisolated private static func defaultInviteKDF() -> any InviteKDF {
    #if LEAF_PROD
    return ProdInviteKDF()
    #else
    return UnimplementedInviteKDF()
    #endif
}

nonisolated private static func defaultInviteBlobCodec() -> any InviteBlobCodec {
    #if LEAF_PROD
    return ProdInviteBlobCodec()
    #else
    return UnimplementedInviteBlobCodec()
    #endif
}
```

`InviteOutboxReader.init` принимает `inviteKDF:` + `inviteBlobCodec:` defaults через статические factory; lazy-инициализирует `InviteService` в `ensureService()`.

Dev/test runs (LEAF_PROD off) — `UnimplementedInviteKDF` + `UnimplementedInviteBlobCodec` throw `.notImplemented` на первом call. Это OK — dev-mode не должен генерировать реальные invites (нет prod relay credential trust). Tests инжектят explicit doubles (recording KDF/Codec).

`@State var inviteOutboxReader = InviteOutboxReader()` в `LeafApp` body; `.environment(inviteOutboxReader)` для main Window scene (как `orgReader` в 5.1.E). `MenuBarContent` НЕ получает — out of 5.2.D scope.

---

## 7. Tests

### 7.1 LeafCoreTests (≈25 new)

| Suite | File | Count |
|---|---|---|
| `InviteOutboundTests` | `Tests/LeafCoreTests/InviteOutboundTests.swift` | 2 |
| `RelayClientTests` | `Tests/LeafCoreTests/RelayClientTests.swift` | ≈12 (URLProtocol stub harness) |
| `InviteServiceTests` | `Tests/LeafCoreTests/InviteServiceTests.swift` | ≈11 (mock RelayClient + recording KDF + recording Codec) |

#### 7.1.1 `RelayClientTests` matrix

URLProtocol-based stub registers responses per request URL+method.

1. `postInvite_201_ReturnsToken` — happy path body `{token, expires_at_ms}` parsed.
2. `postInvite_SendsCorrectJSONBody` — capture URLProtocol request; assert `member_pubkey_hex` lowercased / `blob` base64url no-pad / `expires_at_ms` integer / `Content-Type: application/json`.
3. `postInvite_400_ThrowsInviteRequestRejected_BadInput`.
4. `postInvite_413_ThrowsInviteRequestRejected_Size`.
5. `postInvite_500_ThrowsRelayUnreachable_ServerError`.
6. `postInvite_NetworkError_ThrowsRelayUnreachable_Transport`.
7. `postInvite_MalformedResponseBody_ThrowsRelayUnreachable_MalformedResponse`.
8. `getInvite_200_ReturnsBlobAndExpiry` — base64url decode roundtrip.
9. `getInvite_404_ThrowsInviteNotFound`.
10. `deleteInvite_204_Success`.
11. `deleteInvite_NetworkError_ThrowsRelayUnreachable_Transport`.
12. `init_DefaultBaseURL_OauthGundemTech` — sanity, default URL pin.

**URLProtocol stub harness:** `URLProtocol` subclass с static `requestHandler: ((URLRequest) -> (HTTPURLResponse, Data?, Error?))?`; `URLSessionConfiguration.ephemeral.protocolClasses = [StubURLProtocol.self]`; pass session to `RelayClient(urlSession:)`. `setUp/tearDown` reset static handler.

#### 7.1.2 `InviteServiceTests` matrix

`MockRelayClient` (actor with stubbed responses + recorded calls), `RecordingInviteKDF` (returns fixed SymmetricKey, records args), `RecordingInviteBlobCodec` (returns fixed `InviteBlob`, records args). Deterministic factories: `now`, `randomOTP`, `identity`. Real `Database` через tempDir + `.deterministicTest` encryption mirror `OrgServiceTests`.

1. `generateInvite_HappyPath_ReturnsExpectedOutbound` — full chain; assert returned `token / otp / expiresAtMs / inviteePubkeyHex`.
2. `generateInvite_ReadsActiveTeamKeyBytes` — verify recorded `InvitePlaintext.teamKeyBase64` decodes to keystore bytes.
3. `generateInvite_PassesAdminPubkeyToCodec` — capture codec call; assert `adminPubkey == identity.publicKey.rawRepresentation`.
4. `generateInvite_PassesLowercaseHexToRelay` — uppercase input → lowercase в POST body.
5. `generateInvite_ExpiresAt24Hours` — `expiresAtMs == now + 86_400_000`.
6. `generateInvite_BadHex_ThrowsInvalidPayload` — non-hex chars / wrong length.
7. `generateInvite_NoOrg_ThrowsDatabaseUnavailable` — empty DB.
8. `generateInvite_NoActiveTeamKey_ThrowsDatabaseUnavailable` — org row exists, нет active team_keys row (defensive — shouldn't happen post-5.1.D).
9. `generateInvite_KDFFails_PropagatesInvalidPayload` — `RecordingInviteKDF` throws → propagates.
10. `generateInvite_RelayFails_PropagatesRelayUnreachable` — mock RelayClient throws.
11. `revokeInvite_CallsRelayDelete` — verify call recorded.

### 7.2 LeafCorePrivateTests (≈5 new, gitignored)

`InviteHandshakeIntegrationTests.swift` — admin-side только (full invitee unwrap → 5.2.E):

1. `adminGenerate_RealKDF_RealCodec_RoundTripsPlaintextLocally` — bypass relay; encode blob via `ProdInviteBlobCodec` + `ProdInviteKDF`, decode locally with same wrapKey, assert `InvitePlaintext` field-equality.
2. `adminGenerate_TwoCallsProduceDistinctTokens` — mock relay returns deterministic-distinct tokens; verify `InviteService` doesn't cache.
3. `adminGenerate_BlobBytesMatchVersion0x02` — first byte assertion.
4. `adminGenerate_BlobOverheadMatchesSpec` — `bytes.count - plaintextSize == 61`.
5. `adminGenerate_OTPIs6Digits` — sanity на `secureRandomOTP` (loop N=200, assert pattern `^\d{6}$`).

### 7.3 Manual UI smoke (Stage 7)

Не runnable через Bash — за юзером:

1. Launch debug build (Xcode Run); LEAF_PROD off → expect Generate button показывает `.error("not implemented")` (Unimplemented impls в dev) → confirms wiring shape correct, dev-safe.
2. Switch composition root temporarily на Prod (`-D LEAF_PROD` flag в Xcode scheme или ship Release config) → запустить → ввести valid pubkey hex → Generate → assert sheet shows token (32 chars base64url) + OTP (6 digits) + countdown updates каждую секунду.
3. Click Copy on token → paste в editor → assert match.
4. Click Revoke + Done → sheet dismisses; (optional) curl `GET https://oauth.gundem.tech/v1/invite/<token>` → expect 404 (consumed by DELETE).

Two-Mac E2E (real Anton acceptance) — 5.2.E gate, не 5.2.D.

---

## 8. Plan (commits — atomic, sequential per `superpowers:test-driven-development`)

| # | Commit message | Scope |
|---|---|---|
| 1 | `docs(specs): Phase 5.2.D — RelayClient + InviteService + invite UI spec` | this file |
| 2 | `feat(core): Phase 5.2.D — LeafError relay/invite cases` | LeafError +3 cases (no consumer yet) |
| 3 | `feat(core): Phase 5.2.D — InviteOutbound value type` | InviteOutbound.swift + 2 tests |
| 4 | `feat(core): Phase 5.2.D — RelayClient HTTP wire layer` | Relay/RelayClient.swift + ≈12 tests (URLProtocol stub) |
| 5 | `feat(core): Phase 5.2.D — InviteService admin orchestrator` | InviteService.swift + ≈11 tests (mocks + recording doubles) |
| 6 | `feat(private): Phase 5.2.D — Prod KDF + Codec admin-side integration tests (gitignored)` | InviteHandshakeIntegrationTests.swift + ≈5 moat tests |
| 7 | `feat(app): Phase 5.2.D — InviteOutboxReader Observable + LeafApp wiring` | Reader + LeafApp environment + composition root factories |
| 8 | `feat(app): Phase 5.2.D — GenerateInviteSheet + TeamView Add member CTA` | Sheet view + TeamView edit |

Commits 2-6 — LeafCore/LeafCorePrivate; commits 7-8 — Leaf app target. Each: write tests → run → see fail → implement → run → see pass → commit (per TDD discipline). Scheme matrix runs at Stage 7 verification.

---

## 9. Verification gate (Stage 7)

```bash
cd /Users/ddemidov/Desktop/Leaf/leaf
( cd Packages/LeafCore && swift test ) 2>&1 | tail -20
# Expect "Executed ≈800 tests" (+25 LeafCore, +5 LeafCorePrivate from 5.2.B baseline 770)
# Expect "0 failures"

for s in Leaf LeafAgent LeafMCP LeafCore LeafCorePrivate; do
  xcodebuild -scheme "$s" -configuration Debug build -quiet 2>&1 | tail -3
done
# Expect 5× "BUILD SUCCEEDED"

git status --porcelain | grep -E "LeafCorePrivate.*Prod.*\.swift" || echo "OK: no moat files tracked"
git log --oneline feature/phase-5-2-C..HEAD  # Expect 8 commits, atomic prefixes

# Manual UI smoke (за юзером — see §7.3)
# Two-Mac E2E — 5.2.E
```

**Pre-merge `/pre-push-leaf` checks:**
- `RelayClient` baseURL string `oauth.gundem.tech` — public-safe (whitepaper presence-relay.md mentions abstractly).
- `LeafError.relayUnreachable(reason:)` strings — generic ("server-error", "transport", "malformed-response") не leak'ят moat HKDF info / blob layout.
- `Relay/` directory paths — public-safe (HTTP wire shape already public per relay 5.2.C spec).

---

## 10. Critical files referenced

| Path | Why |
|---|---|
| `2026-05-04-phase-5-2-decomposition.md` §3, §4.5, §4.6, §7 | Contract; out-of-scope rows |
| `2026-05-04-phase-5-2-A-identity-kdf.md` | `IdentityService`, `KeyAgreement`, `InviteKDF` precedent |
| `2026-05-04-phase-5-2-B-invite-blob.md` | `InviteBlob`, `InvitePlaintext`, `InviteBlobCodec` precedent |
| `2026-05-04-phase-5-2-C-relay-invite.md` | Relay wire format (status mapping в `RelayClient`) |
| `2026-05-04-phase-5-1-D-org-service.md` | Pattern: factory injection, `now` defaults, error propagation |
| `2026-05-04-phase-5-1-E-org-views.md` | Pattern: `OrgReader` Observable + state machine + LeafApp environment wiring |
| `Packages/LeafCore/Sources/LeafCore/Crypto/IdentityService.swift` | Consumer (admin priv) |
| `Packages/LeafCore/Sources/LeafCore/Crypto/KeyAgreement.swift` | Consumer (ECDH) |
| `Packages/LeafCore/Sources/LeafCore/Crypto/KeyDerivation.swift` (`InviteKDF`) | Consumer (KDF) + injection target в Reader |
| `Packages/LeafCore/Sources/LeafCore/Crypto/InviteBlobCodec.swift` | Consumer (encode) + injection target |
| `Packages/LeafCore/Sources/LeafCore/Crypto/TeamKeystore.swift` | Consumer (`readTeamKey(id:)`) |
| `Packages/LeafCore/Sources/LeafCore/Team/OrgService.swift` | Pattern: factory injection idiom |
| `Packages/LeafCore/Sources/LeafCore/Database.swift` (team helpers) | Consumer: `readOrg`, `readTeamMembers`, `readActiveTeamKey` |
| `Packages/LeafCore/Sources/LeafCore/LeafError.swift` | Append 3 cases at end |
| `Packages/LeafCore/Sources/LeafCore/Integrations/Slack/SlackTokenRefresher.swift` | URLSession injection precedent |
| `Leaf/Models/OrgReader.swift` | Pattern: lazy-init + state machine for `InviteOutboxReader` |
| `Leaf/Views/Window/Team/TeamView.swift` | Edit target — "+ Add member" CTA insertion |
| `Leaf/Views/Window/Organization/OrganizationView.swift` | Pattern: GlassCard form + `.borderedProminent` button |
| `Leaf/LeafApp.swift` | Composition root edits (factory + environment) |
| `Leaf/Integrations/GitHub/GitHubOAuthService.swift` | Pattern: state machine с associated values |
| `Packages/LeafCore/Sources/LeafCorePrivate/Prod/Crypto/ProdInviteKDF.swift` (gitignored) | Composition root injection target |
| `Packages/LeafCore/Sources/LeafCorePrivate/Prod/Crypto/ProdInviteBlobCodec.swift` (gitignored) | Composition root injection target |

---

## 11. Risks + mitigations

| Risk | Mitigation |
|---|---|
| URLProtocol stub harness flakey (state leakage между tests) | `URLSessionConfiguration.ephemeral` per test; `setUp/tearDown` reset stub `requestHandler` static; pin assert pattern. |
| `RelayClient` actor + URLSession non-actor — concurrency hop overhead на каждом call | Acceptable; invite-генерация — once-per-member-add (rare). Profile if hot-path emerges. |
| OTP entropy 10^6 brute-forceable online | Per decomposition D4: relay GET = one-shot consume → after first GET, OTP space inaccessible online. Manual brute-force бессмыслен (admin notices missing token). 24h TTL bound. |
| `LEAF_PROD` not set в Xcode Debug — Generate button uselessly throws `.notImplemented` | Acceptable for dev. Manual smoke flow §7.3 documents temporary `-D LEAF_PROD` для verification. Prod build (Sparkle ship) автоматически sets flag. |
| KV global eventual consistency (~60s) — admin shows token to invitee, invitee fetches → 404 | Per relay 5.2.C §13: invitee app retry on 404 — 5.2.E concern. 5.2.D admin-side не affected. |
| Pasteboard copy не работает в sandboxed app | macOS Sandbox OFF per architecture контракт (Hardened Runtime ON, Sandbox OFF). `NSPasteboard.general` доступен. |
| Sheet dismiss while `.generating` → Task continuation orphaned | Reader `Task` weak-self; on dismiss reader ничего не делает (ephemeral); upload completes в фоне, KV gets row, admin discards. Acceptable — admin can wait 24h or revoke if remembered token. |
| `InviteService` reads `team_members` self-row но в schema 5.1.B нет `is_self` flag | Single-org-per-device invariant + first inserted member = self admin (5.1.D `OrgService`); `.first` defensive enough. Future multi-self refactor — out of MVP. |
| `inviteRequestRejected(reason:)` reason strings leak server-side validation labels | Use generic strings ("bad-input", "method", "size", "media-type"). Не embed server's exact `400 invite-bad-pubkey` label. `/pre-push-leaf` catches. |
| Composition root inject of moat types в LeafApp.swift — typo risk (forgot `#else` branch) | Mirror 5.1.D `OrgReader.defaultConfig()` pattern strictly; static func with both branches shipping; build matrix Stage 7 catches. |

---

## 12. Out of scope (deferred)

| Excluded | Why | Reserved for |
|---|---|---|
| Invitee accept-flow (`InviteAcceptService`, `InviteAcceptReader`, sheet, Onboarding screen 6) | Full handshake — separate consumer surface | 5.2.E |
| E2E URLProtocol stub admin↔invitee handshake test | Requires invitee orchestrator | 5.2.E |
| Outstanding-invite list UI / "View all my pending invites" | Decomposition §7 row "minimal в 5.2.D if cheap, full deferred" | 5.5+ |
| `presence_outgoing` / `presence_history` / WS broadcast | Separate primary surface | 5.4 |
| Member removal / key rotation | Separate flow | 5.3 |
| QR / deep-link OOB transmission | Decomposition §7 future row | future |
| Audit log "who invited whom" | Out of MVP | future |
| Persisted invite outbox с DB row | Per D2 — minimal in-memory; full UI deferred | 5.5+ |
| KV-propagation-latency UI hint | UX polish | 5.2.E |
| Whitepaper sync (`presence-relay.md`) | Already abstract | 5.2.E ship |

---

*End of spec. On approval → execute commits 1→8 sequentially per TDD discipline. Stage 6 review (`superpowers:code-reviewer` subagent) after commit 8; Stage 7 verification before pushing branch + before 5.2.E stack.*
