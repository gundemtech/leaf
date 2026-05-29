# Phase 5.2 — Decomposition: relay invite endpoints + invite UX + ECDH handshake

**Status:** Active (2026-05-05). Phase 5.2 of Phase 5 ("team presence relay"). Decomposes contract-§9 row 5.2 into sub-phases 5.2.A → 5.2.E.
**Owner:** Alex.
**Stack:** branches off `feature/phase-5-1-E` pending 5.1.A→E unified merge to main.

---

## 1. Context

Phase 5.1.x stack (5.1.A→E) closed 2026-05-05 day. Solo-юзер делает "Create personal org" → 1 row org + 1 row team_members(self-admin) + 1 row team_keys + X25519 keypair + AES-GCM-256 envelope codec — substrate под real consumer'а.

Phase 5.2 даёт первого real consumer'а: **invite handshake** между admin и invitee на разных Mac'ах. Это первый call-site для **X25519 ECDH** + **HKDF-SHA256** helpers (per контракт §9 deviation от 5.1.C — переехали в 5.2 row, потому что invite — first real caller; никакого dead substrate без consumer'а).

**Источники правды (priority при противоречии):**
1. `2026-05-04-phase-5-architecture-contract.md` — §4 (identity model: single-org-per-device), §6 (envelope), §7 (key lifecycle), §8 (relay API surface), §10 (failure modes).
2. `~/Desktop/Leaf/leaf-docs/docs/03-architecture/presence-relay.md` — public-truth invariants (24h token, 6-digit OTP, OOB transmission, X25519 ECDH, HKDF-SHA256 with OTP salt).
3. Существующие patterns в Leaf app (`OAuthService` state machine, `OrgReader` `@Observable` wrapper, `OrgService` factory injection, `Envelope` codec protocol).

---

## 2. Decisions taken (2026-05-05 brainstorm)

| # | Decision | Rationale |
|---|---|---|
| D1 | **Sub-phases 5.2.A→E** mirror 5.1.A-E discipline | Single-phase 5.2 too wide (Swift LeafCore + Private + new TS leaf-relay routes + 2 UI screens + onboarding wire). Sub-phases дают landing checkpoints + sub-rollback granularity. |
| D2 | **X25519 lazy via shared `IdentityService.ensureLocalIdentity()`** | Idempotent; reads file or generates+writes. `OrgService.createPersonalOrg` refactored в 5.2.A вызывать ensureLocalIdentity вместо inline-генерации. Invitee accept-flow и admin generate-invite UI тоже вызывают первым шагом. Никаких orphan keys у юзеров без org/invite. |
| D3 | **admin_pubkey embedded в opaque blob bytes** на relay | Wire shape `POST /v1/invite` body: `{member_pubkey_hex, blob: <bytes>, expires_at_ms}`. Blob layout: `[ver:1B \| admin_pubkey:32B \| nonce:12B \| ct \| tag:16B]` (≥61B overhead, plaintext typically 80-200B). Byte layout + AAD content + HKDF info string + OTP→salt construction — **moat в `LeafCorePrivate`**. Public LeafCore — `InviteBlobCodec` protocol surface. Инвариант контракта §5 "relay sees only opaque encrypted blobs" сохранён буквально. |
| D4 | **GET=one-shot delivery, retry OTP локальный** | GET /v1/invite/:token первый вызов отдаёт blob bytes + помечает consumed=true в KV; subsequent GETs → 404. После delivery invitee хранит blob в RAM и без лимита пробует OTP (AES-GCM tag fail = дешёвая операция; brute-forcing 10^6 6-digit space недоступен online после consume). UX: после 5 failed attempts в session → `Discard invite + ask admin to send again` button. Resolves contract §8 vs §10 apparent conflict ("one-time consume" = delivery, не OTP attempts). |
| D5 | **Accept UI surface — обе точки**: Onboarding screen 6 partial + Organization tab empty-state second CTA | Onboarding для new installs первоначального пути; Organization tab CTA — для existing alpha.9 ship'нутых юзеров без onboarding rerun. Обе точки → `InviteAcceptReader` shared logic. Final integration onboarding flow polishing — 5.5. |
| D6 | **Server-generated invite token** (POST /v1/invite returns token) | Контракт §8 wording. Простота: server validates uniqueness, stores in KV с TTL, returns `{ token, expires_at_ms }`. Admin client не отвечает за uniqueness/collision. URL-safe 24-byte random base64url (32 chars без padding). |
| D7 | **OTP — client-side admin generation** | Admin app генерирует 6 digits (0-999999) cryptographically random, использует как HKDF salt input. Relay никогда не видит OTP (контракт §5 invariant). Admin shows OTP + token в UI после POST returns; transmits OOB (Slack/Telegram). |
| D8 | **Reuse leaf-oauth-relay worker** (не отдельный invite worker) | Phase 4.4 уже ship'нул `oauth.gundem.tech` Cloudflare worker. 5.2.C расширяет его routes на `/v1/invite/*` + добавляет KV namespace binding. Worker name `leaf-oauth-relay` остаётся (cosmetic rename → отдельный chore-PR future). One worker, multiple routes — проще DNS, deploy, monitoring. |
| D9 | **`/v1/` URL prefix** (контракт §8 versioning policy) | All Phase 5 endpoints под `/v1/` from day one. Phase 4.4 OAuth bouncer (`/<provider>/callback`) untouched (existing version-less path). Future `/v2/` for breaking changes with overlap period. |
| D10 | **HTTP request/response — JSON** (контракт-level free choice) | Все 3 invite endpoints используют JSON body + `Content-Type: application/json`. `blob` поле — base64url-encoded bytes (URL-safe, prefix-free, no padding ambiguity). Mirrors how leaf-oauth-relay handles params currently (text/plain) but invite needs structured body. |

---

## 3. Sub-phase decomposition

| Sub-phase | Scope (declarative) | Branch | Cumulative tests |
|---|---|---|---|
| **5.2.A** | `IdentityService.ensureLocalIdentity` (LeafCore) + `KeyAgreement` ECDH wrapper (LeafCore) + `InviteKDF` protocol (LeafCore) + `ProdInviteKDF` HKDF impl (LeafCorePrivate, moat info string) + refactor `OrgService.createPersonalOrg` to delegate identity to `IdentityService` (no behavior change end-user-visible) | `feature/phase-5-2-A` off 5.1.E | 714 → ≈740 |
| **5.2.B** | `InviteBlob` value type + `InvitePlaintext` struct (LeafCore) + `InviteBlobCodec` protocol (LeafCore) + `ProdInviteBlobCodec` AES-GCM-256 impl (LeafCorePrivate, moat byte layout + AAD + nonce gen + JSON plaintext serialization) | stack on 5.2.A | ≈740 → ≈770 |
| **5.2.C** | `leaf-oauth-relay` extension: `POST /v1/invite`, `GET /v1/invite/:token`, `DELETE /v1/invite/:token` + KV namespace `INVITES` + native TTL + Vitest tests (≥10) + `wrangler deploy` | `gundemtech/leaf-relay` repo, `feature/v1-invite` (separate repo, separate PR flow) | leaf-relay: 8 → ≈18 |
| **5.2.D** | `RelayClient` HTTP (LeafCore, URLSession-based, JSON) + `InviteService` (LeafCore high-level admin orchestrator) + Generate-invite UI (TeamView "+ Add member" admin-only sheet) + `InviteOutboxReader` Observable | stack on 5.2.B (post-5.2.C deploy) | ≈770 → ≈800 |
| **5.2.E** | `InviteAcceptService` (LeafCore invitee orchestrator) + `InviteAcceptReader` Observable + Accept-invite View (modal/sheet) + Onboarding screen 6 partial + OrganizationView empty-state second CTA + E2E integration test (full handshake локально через URLProtocol stub) + landing commit `docs(shared)` | stack on 5.2.D | ≈800 → ≈815 |

**Total ship surface end-of-5.2:** Two MacBook'а на одной командной teamKey без presence broadcast yet (broadcast → 5.4). On-disk: 2 rows team_members per device + 1 row org + 1 row team_keys + X25519 priv + matching teamKey file. Wire surface: 3 new HTTPS endpoints live на `oauth.gundem.tech/v1/invite/*`.

---

## 4. Cross-phase invariants (locked here)

Эти constants единые для всех 5.2.A-E. Если sub-phase spec нужно отклонение — обновить **сюда** сначала, потом sub-phase.

### 4.1 File / module layout

| Артефакт | Путь | Модуль |
|---|---|---|
| `IdentityService.swift` | `Packages/LeafCore/Sources/LeafCore/Crypto/IdentityService.swift` | LeafCore (public) |
| `KeyAgreement.swift` (ECDH wrapper) | `Packages/LeafCore/Sources/LeafCore/Crypto/KeyAgreement.swift` | LeafCore (public) |
| `KeyDerivation.swift` (`InviteKDF` protocol) | `Packages/LeafCore/Sources/LeafCore/Crypto/KeyDerivation.swift` | LeafCore (public) |
| `ProdInviteKDF.swift` | `Packages/LeafCorePrivate/Sources/LeafCorePrivate/Prod/Crypto/ProdInviteKDF.swift` | LeafCorePrivate (gitignored moat) |
| `InviteBlob.swift` (value type) | `Packages/LeafCore/Sources/LeafCore/Team/InviteBlob.swift` | LeafCore (public) |
| `InviteBlobCodec.swift` (protocol) | `Packages/LeafCore/Sources/LeafCore/Crypto/InviteBlobCodec.swift` | LeafCore (public) |
| `ProdInviteBlobCodec.swift` (AES-GCM impl) | `Packages/LeafCorePrivate/Sources/LeafCorePrivate/Prod/Crypto/ProdInviteBlobCodec.swift` | LeafCorePrivate (gitignored moat) |
| `RelayClient.swift` | `Packages/LeafCore/Sources/LeafCore/Relay/RelayClient.swift` | LeafCore (public) |
| `InviteService.swift` (admin) | `Packages/LeafCore/Sources/LeafCore/Team/InviteService.swift` | LeafCore (public) |
| `InviteAcceptService.swift` (invitee) | `Packages/LeafCore/Sources/LeafCore/Team/InviteAcceptService.swift` | LeafCore (public) |
| `InviteOutboxReader.swift` (admin UI) | `Leaf/Models/InviteOutboxReader.swift` | Leaf app |
| `InviteAcceptReader.swift` (invitee UI) | `Leaf/Models/InviteAcceptReader.swift` | Leaf app |
| Generate-invite sheet | `Leaf/Views/Window/Team/GenerateInviteSheet.swift` | Leaf app |
| Accept-invite sheet | `Leaf/Views/Window/Organization/AcceptInviteSheet.swift` | Leaf app |
| Onboarding screen 6 | `Leaf/Views/Onboarding/OnboardingTeamStep.swift` | Leaf app |

### 4.2 Wire format

**Relay base URL:** `https://oauth.gundem.tech` (existing `leaf-oauth-relay` worker, custom domain unchanged). Phase 5.2 adds `/v1/invite/*` routes.

**`POST /v1/invite`:**

```jsonc
// Request (Content-Type: application/json)
{
  "member_pubkey_hex": "<64 chars hex>",   // invitee's X25519 pub
  "blob": "<base64url bytes>",              // wrapped invite blob
  "expires_at_ms": 1760000000000            // server enforces ≤ now+24h+60s skew
}
// Response 201
{ "token": "<base64url 32 chars>", "expires_at_ms": 1760000000000 }
// Response 400 на bad input
// Response 413 на blob > 8KB ceiling
// Response 415 на non-JSON Content-Type
```

**`GET /v1/invite/:token`:**

```jsonc
// Response 200 (one-shot — KV.delete before return)
{ "blob": "<base64url bytes>", "expires_at_ms": 1760000000000 }
// Response 404 — consumed already / expired / never existed (indistinguishable)
```

**`DELETE /v1/invite/:token`:**

```
// Response 204 — always (idempotent — never reveals existence)
```

**Token format:** server-generated, 24 random bytes from `crypto.getRandomValues`, encoded base64url (32 chars без padding). Stored как KV key directly.

### 4.3 Invite blob layout (moat — `LeafCorePrivate`)

```
[ ver:1B | admin_pubkey:32B | nonce:12B | ciphertext | tag:16B ]
       61 bytes fixed overhead, plaintext typically 80-200 bytes
       → blob 141-261 bytes typical
```

`ver = 0x02` для invite (отличается от presence envelope `ver = 0x01`). Implementations MUST reject unknown version.

**Plaintext (JSON in initial impl, MessagePack reserved для post-MVP if size matters):**

```json
{
  "team_key": "<base64 32B>",
  "team_key_id": "<UUID lowercase>",
  "org_id": "<UUID lowercase>",
  "org_name": "<utf8>",
  "admin_member_id": "<UUID lowercase>",
  "admin_display_name": "<utf8>",
  "issued_at_ms": 1760000000000
}
```

**AAD = full 45-byte plaintext header** (binds version + admin_pubkey + nonce — header tamper invalidates AES-GCM tag).

**HKDF derivation** (info string moat):

```
shared_secret = X25519(admin_priv, invitee_pub)  // = X25519(invitee_priv, admin_pub)
otp_salt      = SHA256("<MOAT-prefix>" || otp_digits_utf8)  // moat
wrap_key      = HKDF-SHA256(ikm=shared_secret, salt=otp_salt, info="<MOAT>", L=32)
```

Exact info string + salt construction — `LeafCorePrivate/Prod/Crypto/ProdInviteKDF.swift` (gitignored).

### 4.4 Test target conventions

| Target | Existing baseline | After 5.2 end |
|---|---|---|
| `LeafCoreTests` (public) | 714 | ≈815 |
| `LeafCorePrivateTests` (gitignored moat) | ≥30 | ≈45 |
| leaf-relay Vitest | 8 | ≈18 |

Patterns:
- Crypto unit tests: deterministic via injectable RNG factories (mirror `OrgService` factory injection).
- Integration tests: tempDir + `.deterministicTest` encryption (mirror `OrgPersistenceIntegrationTests`).
- HTTP tests: URLProtocol stub harness (new в 5.2.D).
- E2E (5.2.E): full admin/invitee handshake locally — admin generates blob → URLProtocol stub captures POST → invitee fetches via stub GET → unwrap → assert rows materialize.

### 4.5 RelayClient signature (locked here, impl in 5.2.D)

```swift
public actor RelayClient: Sendable {
    public init(baseURL: URL = URL(string: "https://oauth.gundem.tech")!,
                session: URLSession = .shared)

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

### 4.6 LeafError additions (per sub-phase)

5.2.A: (none — `keyFileCorrupted` reused for IdentityService).
5.2.B: `inviteBlobMalformed`, `inviteOTPInvalid`.
5.2.D: `relayUnreachable(reason: String)`, `inviteNotFound`, `inviteRequestRejected(reason: String)`.
5.2.E: `inviteAlreadyAccepted`.

---

## 5. Critical files to read before each sub-phase

| File | Why |
|---|---|
| `2026-05-04-phase-5-architecture-contract.md` (§4, §6, §7, §8, §10) | Contract invariants 5.2 obeys |
| `2026-05-04-phase-5-1-D-org-service.md` | Pattern for LeafCore service + factory injection + tests |
| `2026-05-04-phase-5-1-E-org-views.md` | Pattern for `@Observable` reader + UI state machine + integration test harness |
| `Packages/LeafCore/Sources/LeafCore/Crypto/Envelope.swift` | EnvelopeCodec protocol style; mirror for InviteBlobCodec |
| `Packages/LeafCore/Sources/LeafCore/Crypto/TeamKeystore.swift` | Atomic file write + 0o600 + length validation pattern |
| `Packages/LeafCore/Sources/LeafCore/Team/OrgService.swift` | Refactor target (5.2.A); also factory injection idiom |
| `Packages/LeafCore/Sources/LeafCore/Crypto/FileKeyStore.swift` | Original keystore pattern (5.2.A IdentityService mirrors) |
| `Leaf/Models/OrgReader.swift` | Pattern for InviteOutboxReader + InviteAcceptReader |
| `Leaf/Integrations/GitHub/OAuthService.swift` | State machine pattern for invite UX state machines |
| `~/Desktop/Leaf/leaf-relay/src/index.ts` | Existing handler style (hand-rolled fetch handler, no framework) |
| `~/Desktop/Leaf/leaf-relay/wrangler.toml` | KV namespace addition target |
| `~/Desktop/Leaf/leaf-relay/CLAUDE.md` | leaf-relay coding rules ("no state without justification") |
| `~/Desktop/Leaf/leaf-docs/docs/03-architecture/presence-relay.md` | Public-truth invite flow shape |

---

## 6. Verification gate before ship

End-of-Phase-5.2 (after 5.2.E ship), before alpha bump:

```bash
cd ~/Desktop/Leaf/leaf/Packages/LeafCore && swift test  # ≈815+ pass
cd ~/Desktop/Leaf/leaf-relay && npm test                 # ≈18 pass
cd ~/Desktop/Leaf/leaf
xcodebuild -scheme Leaf            -configuration Debug build  # SUCCESS (×5 schemes)
xcodebuild -scheme LeafAgent       -configuration Debug build
xcodebuild -scheme LeafMCP         -configuration Debug build
xcodebuild -scheme LeafCore        -configuration Debug build
xcodebuild -scheme LeafCorePrivate -configuration Debug build

# Pre-push moat scan
/pre-push-leaf

# Wrangler deploy verification
curl -i 'https://oauth.gundem.tech/v1/invite/nonexistent-token' # → 404 with no-store

# Two-Mac E2E (manual; canonical "did 5.2 actually ship" gate)
# Alex + Sasha each run alpha build → admin Alex generates invite UI → copy pubkey hex
# to Sasha via Slack → Sasha on his Mac creates fresh-X25519 (открыл Accept-invite UI) → posts
# pubkey back → Alex completes invite → posts token+OTP via Slack → Sasha accepts → assert
# Sasha's Organization tab shows Leaf org с двумя members. SQLCipher REPL cross-check matching
# teamKey bytes.

# leaf-docs sync
git -C ~/Desktop/Leaf/leaf-docs pull --ff-only
# Append changelog entry "5.2 — invite handshake live (X25519+HKDF+OTP)" + push
```

---

## 7. Out of scope for 5.2 (deferred)

| Excluded | Why | Reserved for |
|---|---|---|
| Onboarding screen 6 final styling / motion / copy polish | "Partial" wired in 5.2.E; final polish — 5.5 | 5.5 |
| Member removal / key rotation | Separate flow surface | 5.3 |
| Presence WS broadcast / live team grid | Separate primary surface | 5.4 |
| Re-invite flow after expiration | Admin manually generates new invite (no auto-renew); MVP-acceptable | future |
| Invite via QR code / deep link | OOB paste sufficient в MVP | future |
| Invite-list management UI ("show all my outstanding invites + revoke") | Minimal version в 5.2.D `InviteOutboxReader` if cheap; full UI deferred | 5.5+ |
| Audit log "who invited whom" | Out of MVP (presence_outgoing audit log в 5.4 covers presence) | future |
| Cosmetic worker rename `leaf-oauth-relay` → `leaf-relay` | Cleanup PR | future |

---

## 8. Risks + mitigations

| Risk | Mitigation |
|---|---|
| OOB transmission UX awkward (paste pubkey to Slack, paste token+OTP back) | Acceptable в MVP per whitepaper; copy-buttons + clear instructions; future flow could use deep links / QR codes (5.6+ trk) |
| KV propagation latency между PUT и GET (Cloudflare KV eventually consistent globally — typically 60s) | 5.2.C spec mentions; admin UI surfaces "Invite ready in ~30s" + invitee-side retry на initial 404 |
| Two-Mac dev infra cost | Alex + Sasha both have Mac's; manual E2E feasible. Two-Mac CI not in scope. |
| Worker name `leaf-oauth-relay` becoming misleading | Cosmetic. Defer rename. |
| Onboarding screen 6 churn между 5.2.E partial и 5.5 final | Partial = minimal viable wiring; 5.5 free to redesign visually без API breakage. State machine в `InviteAcceptReader` — invariant target. |
| 5.2.B ProdInviteBlobCodec leak via crash log / error message | Spec discipline: error messages generic ("invite blob malformed" не "expected version 2 got 1"). KAT regression test + `/pre-push-leaf` scan catches accidental info-string leak. |
| "Invitee enters wrong invitee pubkey" — admin generates blob с wrong pubkey, decryption fails on accept | Symptom = AES-GCM tag fail на unwrap, surfaces same as wrong OTP. UX message: "OTP doesn't match — ask admin to send again" + admin-side "Revoke + regenerate". Acceptable; matches whitepaper failure modes. |

---

*End of decomposition. Sub-phase specs (5.2.A immediately, B-E in their own sessions per "Одна phase = одна сессия") live alongside contract в `docs/superpowers/specs/`.*
