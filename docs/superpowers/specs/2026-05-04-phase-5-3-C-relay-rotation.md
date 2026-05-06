# Phase 5.3.C — Relay endpoints + `RelayClient` rotation methods (wire)

**Status:** Active (2026-05-06). Third sub-phase of Phase 5.3 ("member removal + team key rotation").
**Owner:** Dmitrii.
**Stack base:** `feature/phase-5-3-B` (5.3.B landed @ 852 SPM tests).
**Branch:** `feature/phase-5-3-C`.

---

## 1. Context

Phase 5.3.B закрыл codec substrate — `RotationBlob` / `RotationBlobHeader.peek` / `RotationBlobCodec` (Unimplemented + `ProdRotationBlobCodec` AES-GCM moat) / `RotationKDF` (HKDF-SHA256 moat). Admin orchestrator 5.3.D и peer fetch loop 5.3.E смогут wrap'нуть/unwrap'нуть byte payload, но distribution layer пока что отсутствует — admin не может POST'нуть wrapped blob, peer не может drain'ить mailbox.

Phase 5.3.C — **wire surface sub-phase**: HTTP endpoints в `gundemtech/leaf-relay` + `RelayClient` extension в `gundemtech/leaf`. Peer-pubkey-keyed mailbox с list-then-ACK semantic (overview AD #2). Без 5.3.C 5.3.D `KeyRotationService.rotate(...)` не имеет куда POST'нуть N-1 fan-out wraps.

**Зачем сейчас:** 5.3.D admin flow требует `RelayClient.postRotationBlob` для each remaining peer + each removed peer (tombstone). 5.3.E peer flow требует `fetchPendingRotations` + `ackRotation`. Этот phase materializes wire layer + контракт между leaf и leaf-relay, оставляя SPM track unblocked через URLProtocol stubs (mirror 5.2.D pattern).

**Источники правды (priority при противоречии):**

1. `2026-05-04-phase-5-architecture-contract.md` §8 (Relay API surface) + §9 row 5.3 (deliverable matrix — этот phase locks "TBD").
2. `.claude/plans/phase-5-3-overview.md` §5.3.C — locked scope, AD #2 (list-then-ACK), AD #8 (parallel work-stream).
3. `Packages/LeafCore/Sources/LeafCore/Relay/RelayClient.swift` — actor pattern + status mapping.
4. `~/Desktop/Leaf/leaf-relay/src/invite.ts` + `tests/invite.test.ts` — TS handler / Vitest scaffold.
5. `Packages/LeafCore/Tests/LeafCoreTests/RelayClientTests.swift` — URLProtocol stub harness.

---

## 2. Scope

### Входит

#### `gundemtech/leaf` (client side, SPM)

| Артефакт | Файл | Заметка |
|---|---|---|
| `RotationToken` value type | `Packages/LeafCore/Sources/LeafCore/Relay/RotationToken.swift` (новый) | `{value: String, expiresAtMs: Int64}` mirror `InviteToken` |
| `RotationFetched` value type | `Packages/LeafCore/Sources/LeafCore/Relay/RotationFetched.swift` (новый) | `{rotationID: String, blob: Data, expiresAtMs: Int64}` |
| `RelayClient.postRotationBlob` | `Packages/LeafCore/Sources/LeafCore/Relay/RelayClient.swift` (edit, `// MARK: - Rotation`) | POST `/v1/key-rotation` → `RotationToken` |
| `RelayClient.fetchPendingRotations` | same | GET `/v1/key-rotation/by-peer/:peer_pubkey_hex` → `[RotationFetched]` |
| `RelayClient.ackRotation` | same | DELETE `/v1/key-rotation/:rotation_id` (idempotent 204) |
| `LeafError` +1 case | `Packages/LeafCore/Sources/LeafCore/LeafError.swift` (edit) | `rotationRequestRejected(reason: String)` |
| Public tests | `Tests/LeafCoreTests/RelayClientRotationTests.swift` (новый) | 12-16 status-mapping + body-shape + parsing cases |
| Contract amendment | `docs/superpowers/specs/2026-05-04-phase-5-architecture-contract.md` (edit §8 + §9 row 5.3) | TBD → concrete endpoint shapes |

#### `gundemtech/leaf-relay` (TypeScript / Cloudflare Worker, отдельный приватный repo)

| Артефакт | Файл | Заметка |
|---|---|---|
| `handleKeyRotation` router | `src/key-rotation.ts` (новый) | POST/GET/DELETE dispatch + helpers |
| Index route wiring | `src/index.ts` (edit) | `/v1/key-rotation` + `/v1/key-rotation/...` paths |
| Env binding | `wrangler.toml` (edit) | new KV namespace `KEY_ROTATIONS` (или reuse `INVITES` namespace? — см. §6) |
| `Env` interface +1 field | `src/index.ts` (edit) | `KEY_ROTATIONS: KVNamespace` |
| Vitest tests | `tests/key-rotation.test.ts` (новый) | full POST/GET/DELETE coverage с cloudflare:test fixture |

### НЕ входит (явно отложено)

- **Admin orchestrator** `KeyRotationService` / `MemberRemovalService` / `RotationOutbox` → 5.3.D (first caller of `postRotationBlob` x N peers).
- **Peer fetch loop** `RotationFetchService` / `RotationFetchScheduler` → 5.3.E.
- **UI**: Remove member sheet / RemovedFromTeamBanner / TeamView per-row context menu → 5.3.E.
- **Composition root** wiring `RelayClient` rotation methods в `KeyRotationService` / `RotationFetchService` — те consumer'ы ещё не существуют. RelayClient extension живёт substrate-style, mirror 5.2.D landing pattern.
- **Wrangler deploy** + live curl smoke на `oauth.gundem.tech/v1/key-rotation/*` — manual за юзером после Vitest green (decomposition like 5.2.C).
- **Forward-compat** rate limiting / abuse mitigation на relay — relay = honest-but-curious, current cap = TTL + composite-key dedup. Stricter per-IP / per-pubkey rate limits откладываются на ops-level если сурфейсится abuse в alpha.
- **DELETE на peer-bulk** — phase ACKs single rotation_id at a time (peer drains array, ACKs each). Bulk endpoint — premature optimization до 5.4 traffic measurements.

---

## 3. Wire format

### 3.1 `POST /v1/key-rotation`

**Request:**
- Method: `POST`
- Content-Type: `application/json`
- Body:
  ```json
  {
    "peer_pubkey_hex": "<64 hex chars (X25519 public)>",
    "blob": "<base64url no-pad RotationBlob bytes>",
    "expires_at_ms": <int64 unix ms>
  }
  ```

**Response 201 Created:**
```json
{ "rotation_id": "<32 url-safe chars>", "expires_at_ms": <int64> }
```

**Idempotency:** primary KV key derived от `(peer_pubkey_hex, new_key_id_hex)`. Server peeks blob to extract `new_key_id` per `RotationBlobHeader` layout (exact byte offsets — moat) → hex-encode → composite key. Если composite-key already exists → return existing `rotation_id` со status 201 (same body, response identical to first POST). New POST → `randomToken32()` + double-write (primary + reverse).

**4xx codes:**
- 400 `bad-input`: malformed JSON / missing field / wrong type / non-hex pubkey / pubkey != 64 chars / blob not base64url-no-pad / blob bytes < 65 (peek-fail) / blob version != 0x03 / `expires_at_ms` past or > now+24h.
- 405 `method`: any non-POST на `/v1/key-rotation` без trailing path.
- 413 `size`: raw body > 4KB; decoded blob > 2KB.
- 415 `media-type`: Content-Type не начинается с `application/json`.

**5xx:** 500 `server-error` на KV write fail.

### 3.2 `GET /v1/key-rotation/by-peer/:peer_pubkey_hex`

**Request:**
- Method: `GET`
- Path: `/v1/key-rotation/by-peer/<64-hex>`
- Accept: `application/json` (advisory).

**Response 200 OK:**
```json
{
  "rotations": [
    { "rotation_id": "<32 url-safe>", "blob": "<base64url no-pad>", "expires_at_ms": <int64> },
    ...
  ]
}
```

Empty mailbox → `{"rotations": []}` (200, не 404). **Server does NOT delete** — peer ACKs explicitly через DELETE.

Cap N=20 — defensive; в норме мало pending под TTL 24h. Если `KV.list` возвращает > 20 — return first 20 (sorted by creation order via KV list metadata `name` lex sort — composite key `rot:<peer>:<newkid>` подойдёт, `newkid` UUID hex sortable enough для FIFO-ish behavior).

**4xx:**
- 400 `bad-input`: pubkey path component не 64 hex chars.
- 405: any non-GET / non-DELETE на этом path (но DELETE на этом path не is — DELETE пользует `/v1/key-rotation/:rotation_id`).
- 404 `not-found` reserved для unknown sub-routes pattern (consistency с invite.ts `/v1/invite/...` handler) — но valid pubkey всегда returns 200 с possibly-empty array.

**5xx:** 500 `server-error` на KV list fail.

### 3.3 `DELETE /v1/key-rotation/:rotation_id`

**Request:**
- Method: `DELETE`
- Path: `/v1/key-rotation/<32-url-safe-chars>`

**Response 204 No Content** — **always**, regardless of:
- Token shape valid / invalid (no existence-leak per invite §4.3 spec precedent).
- Token actually existed in KV / уже purged.

Internally: если token shape matches `[A-Za-z0-9_-]{32}` → reverse lookup `rot-id:<rotation_id>` → if hit, delete primary `rot:<peer>:<newkid>` AND reverse `rot-id:<rotation_id>`. KV.delete is no-op on missing keys.

**4xx:** None surfaced — bad shape silently swallowed → 204.

**5xx:** 500 `server-error` только на KV unrecoverable error (`server-error` log, surfaces to client как 500). Decision: prefer 500 over 204 при KV failure чтобы peer retried ACK; absent retry leaves mailbox stuck до TTL.

### 3.4 KV storage scheme

- `rot:<peer_pubkey_hex>:<new_key_id_hex>` → JSON `{rotation_id, blob_b64, expires_at_ms}` (primary; lex-sortable; drain via `KV.list({prefix})`).
- `rot-id:<rotation_id>` → string `<peer_pubkey_hex>:<new_key_id_hex>` (reverse lookup для DELETE).

Both keys написаны с `expirationTtl = floor((expires_at_ms - now)/1000)`, clamped `[60s, 86460s]`. Both auto-purge на TTL expiry → no zombie reverse mappings.

Limits constants:
- `MAX_RAW_BODY_BYTES = 4 * 1024` (POST raw text size pre-JSON-parse).
- `MAX_BLOB_BYTES = 2 * 1024` (decoded blob size; real ≈ 270B = 93 fixed overhead + ~150-200B JSON plaintext).
- `MAX_FUTURE_MS = 24 * 60 * 60 * 1000 + 60 * 1000` (mirror invite slack).
- `KV_MIN_TTL_S = 60` (CF KV minimum).
- `MAX_PENDING_PER_PEER = 20` (defensive list cap).

---

## 4. Module layout

### 4.1 `RotationToken`

```swift
// Packages/LeafCore/Sources/LeafCore/Relay/RotationToken.swift
public struct RotationToken: Sendable, Hashable {
    public let value: String
    public let expiresAtMs: Int64
    public init(value: String, expiresAtMs: Int64) { ... }
}
```

### 4.2 `RotationFetched`

```swift
// Packages/LeafCore/Sources/LeafCore/Relay/RotationFetched.swift
public struct RotationFetched: Sendable, Hashable {
    public let rotationID: String
    public let blob: Data
    public let expiresAtMs: Int64
    public init(rotationID: String, blob: Data, expiresAtMs: Int64) { ... }
}
```

### 4.3 `RelayClient` extension (под `// MARK: - Rotation` секцией после invite block)

```swift
public func postRotationBlob(peerPubkeyHex: String,
                             blob: Data,
                             expiresAtMs: Int64) async throws -> RotationToken

public func fetchPendingRotations(forPeerPubkeyHex peerPubkeyHex: String) async throws -> [RotationFetched]

public func ackRotation(rotationID: String) async throws
```

Internals: 3 private parsers (`parseRotationToken`, `parseRotationsArray`) + reuse existing `send(_:)` + `parseInt64(_:)`. 

Status mapping (mirror invite сheme):

| HTTP | post | get | delete | Throws |
|---|---|---|---|---|
| 201 | RotationToken | — | — | — |
| 200 | — | [RotationFetched] | — | — |
| 204 | — | — | success | — |
| 400 | — | — | — | `.rotationRequestRejected("bad-input")` |
| 405 | — | — | — | `.rotationRequestRejected("method")` |
| 413 | — | — | — | `.rotationRequestRejected("size")` |
| 415 | — | — | — | `.rotationRequestRejected("media-type")` |
| 500 | — | — | — | `.relayUnreachable("server-error")` (reuse existing) |
| transport throw | — | — | — | `.relayUnreachable("transport")` (reuse) |
| unparseable / unexpected | — | — | — | `.relayUnreachable("malformed-response")` (reuse) |

DELETE specifically — 204 = success, 405/500 → throws, anything else (including 404) → `.relayUnreachable("malformed-response")`. Note: relay always returns 204 на DELETE per existence-hiding contract → 404 path фактически dead code, но defensive guard кейс.

### 4.4 `LeafError` +1 case

```swift
// Phase 5.3.C — RelayClient rotation methods (POST/GET 4xx surfaces).
case rotationRequestRejected(reason: String)
```

### 4.5 leaf-relay `src/key-rotation.ts`

Mirror `invite.ts` structure:

```typescript
export async function handleKeyRotation(request: Request, url: URL, env: Env): Promise<Response> {
  if (url.pathname === "/v1/key-rotation") {
    if (request.method !== "POST") return methodNotAllowed("POST");
    return handleKeyRotationPost(request, env);
  }

  if (url.pathname.startsWith("/v1/key-rotation/by-peer/")) {
    if (request.method !== "GET") return methodNotAllowed("GET");
    const pubkey = url.pathname.slice("/v1/key-rotation/by-peer/".length);
    return handleKeyRotationDrain(pubkey, env);
  }

  if (url.pathname.startsWith("/v1/key-rotation/")) {
    if (request.method !== "DELETE") return methodNotAllowed("DELETE");
    const rotationID = url.pathname.slice("/v1/key-rotation/".length);
    return handleKeyRotationAck(rotationID, env);
  }

  return reject(404, "key-rotation-not-found");
}
```

Helpers:
- `handleKeyRotationPost` — parse JSON, validate fields, peek blob to extract `new_key_id_hex` per `RotationBlobHeader` layout (exact byte offsets — moat), lookup composite-key (idempotency), KV.put primary + reverse on miss, return 201.
- `handleKeyRotationDrain` — validate hex shape; `KV.list({prefix: 'rot:<peer>:', limit: MAX_PENDING_PER_PEER})` returns name list (CF KV `list` does NOT return values); for each name, `KV.get(name)` to fetch JSON value; `Promise.all` parallel; parse + assemble array; return 200.
- `handleKeyRotationAck` — silent no-op on bad shape (return 204), else reverse lookup, double-delete, return 204.

Constants reused from `invite.ts` где possible (re-export или extract to `lib/`). Decision: **inline constants** в `key-rotation.ts` — different limits than invite, copy-pattern мирно (don't overengineer).

### 4.6 leaf-relay `src/index.ts` route wiring

```typescript
if (
  url.pathname === "/v1/key-rotation" ||
  url.pathname.startsWith("/v1/key-rotation/")
) {
  return handleKeyRotation(request, url, env);
}
```

Inserted before the trailing 404 fallback, after invite block.

### 4.7 leaf-relay `wrangler.toml` KV binding

```toml
[[kv_namespaces]]
binding = "KEY_ROTATIONS"
id = "<TBD-on-deploy-by-Dmitrii>"
preview_id = "<TBD>"
```

`Env` interface +1 field: `KEY_ROTATIONS: KVNamespace`.

**Decision:** separate KV namespace, NOT reuse `INVITES`. Reasons: (a) disjoint key-prefix lookup (avoid edge case где invite token коллизит с rotation_id randomToken32 — same charset/length); (b) ops-level separation simplifies binding-level analytics; (c) per-namespace TTL/limit policies могут diverge в будущем без migration. Trade-off: +1 wrangler.toml line, +1 deploy step (юзер runs `wrangler kv namespace create KEY_ROTATIONS` once); minor.

---

## 5. Tests

### 5.1 `RelayClientRotationTests.swift` (SPM, public)

Mirror `RelayClientTests` — use existing `RelayMockURLProtocol` private class via `@testable import LeafCore` (или duplicate file-local если test isolation needed; precedent: separate file). Decision: **duplicate** harness in this file для test independence — invite test file owns its `RelayMockURLProtocol`; same here. Each test file owns its stub class to avoid cross-file static state hazards.

**Coverage:**

- **postRotationBlob:**
  - `_201_ReturnsToken` — happy path body parse.
  - `_SendsCorrectJSONBody` — assert URL path `/v1/key-rotation`, method POST, Content-Type, body shape `{peer_pubkey_hex, blob (base64url-no-pad), expires_at_ms}`.
  - `_400_ThrowsRotationRequestRejected_BadInput`.
  - `_413_ThrowsRotationRequestRejected_Size`.
  - `_415_ThrowsRotationRequestRejected_MediaType`.
  - `_500_ThrowsRelayUnreachable_ServerError`.
  - `_NetworkError_ThrowsRelayUnreachable_Transport`.
  - `_MalformedResponseBody_ThrowsRelayUnreachable_MalformedResponse`.

- **fetchPendingRotations:**
  - `_200_EmptyArray_ReturnsEmpty` — `{"rotations": []}` → `[]`.
  - `_200_PopulatedArray_ReturnsItems` — multi-item parse, blob base64url decode.
  - `_SendsCorrectURLPath` — assert path `/v1/key-rotation/by-peer/<hex>`, method GET.
  - `_400_ThrowsRotationRequestRejected_BadInput`.
  - `_500_ThrowsRelayUnreachable_ServerError`.
  - `_MalformedResponseBody_ThrowsRelayUnreachable_MalformedResponse`.
  - `_MissingRotationsKey_ThrowsRelayUnreachable_MalformedResponse`.

- **ackRotation:**
  - `_204_Success` — happy path.
  - `_404_ThrowsRelayUnreachable_MalformedResponse` — defensive (relay always 204; this proves codepath rejects unexpected).
  - `_NetworkError_ThrowsRelayUnreachable_Transport`.
  - `_500_ThrowsRelayUnreachable_ServerError`.
  - `_SendsCorrectURLPath` — assert path `/v1/key-rotation/<id>`, method DELETE.

**Acceptance:** SPM Δ ≈ +18-22 cases (chasing accuracy на 12-16 estimate в overview because of array parsing edge cases). Total expected: 852 → ~870-874.

### 5.2 leaf-relay `tests/key-rotation.test.ts` (Vitest)

Mirror `tests/invite.test.ts` structure — `cloudflare:test` fixture, `SELF.fetch`. Test groups:

- **POST /v1/key-rotation:**
  - 201 valid body → returns `{rotation_id, expires_at_ms}` matching schema.
  - Stores primary + reverse в KV.
  - Idempotency: second POST with same `(peer_pubkey, new_key_id)` returns same `rotation_id`.
  - 400 missing field / non-hex pubkey / wrong-length pubkey / non-base64url blob / blob too short for peek / blob version != 0x03.
  - 413 raw body > 4KB / decoded blob > 2KB.
  - 415 non-JSON Content-Type.
  - 400 expires_at past / > 24h+slack future.
  - 405 PUT/PATCH/DELETE на base path.

- **GET /v1/key-rotation/by-peer/:hex:**
  - 200 empty array on no pending.
  - 200 with N items on pending (write 2-3 fixtures, expect both in response).
  - 400 bad pubkey shape.
  - 405 POST/PUT на этом path.
  - Confirms relay does NOT delete после GET (re-GET returns same data).

- **DELETE /v1/key-rotation/:rotation_id:**
  - 204 valid token → primary + reverse both purged.
  - 204 unknown well-formed token (idempotent existence-hiding).
  - 204 malformed token shape (no leak).
  - After DELETE, GET drain on same peer doesn't include that rotation.

**Acceptance:** Vitest всё green локально (`cd ~/Desktop/Leaf/leaf-relay && npm test`). Live deploy + curl smoke за юзером (decomposition like 5.2.C — Stage 7 manual gate).

---

## 6. Threat model + invariants

### 6.1 Capability bearer model

`peer_pubkey_hex` в URL path = bearer capability. Anyone who knows the pubkey can drain the mailbox. Per architecture contract §4 (relay = honest-but-curious): blob is encrypted under admin↔peer ECDH-derived wrapKey + admin-bound HKDF info string; even leaked pubkey yields opaque bytes only. Peer pubkey не is secret — admin can reveal during invite handshake. Same threat model как invite token-as-capability.

### 6.2 Idempotency guarantee

Composite-key dedup на `(peer_pubkey_hex, new_key_id_hex)` гарантирует: admin retry'ит POST после транспорт-ошибки → same rotation_id, no mailbox bloat. Critical для 5.3.D `RotationOutbox` resume flow (write-ahead → POST → mark `posted`; on crash mid-iteration, resumed POST'ы are idempotent at relay).

### 6.3 No relay-side encryption / decryption

Relay handles only opaque base64url'ed bytes. Server CANNOT distinguish `.rotation` from `.tombstone` blob (both опаковые AES-GCM ciphertext — version byte AAD-bound). Server CANNOT verify wrap target — anyone с peer pubkey может POST any byte string ≤ 2KB; only valid `RotationBlobHeader` peek (ver=0x03 + offsets) admitted. Wrap correctness validated peer-side at `decode` time (AES-GCM tag fail → rejected silently).

### 6.4 List-then-ACK race protection

Survives "fetched but crashed before installing" — peer fetches blob, crashes between unwrap и `insertTeamKey`/`deprecateTeamKey`/`ackRotation` DELETE → on relaunch, mailbox still has rotation. Peer drains again, same blob, `insertTeamKey` should be идемпотентным (5.1.B contract — `insertTeamKey` strict INSERT throws on duplicate `id`; **5.3.E will need to handle this ON CONFLICT IGNORE**, flagged in §10).

### 6.5 Mailbox flooding mitigation

Cap N=20 на drain return. Real flood vector — admin POSTs 100 spurious rotations с different `new_key_id`. TTL 24h auto-purges. Если flood persists в alpha — ops-level rate limiting на CF Workers (out of 5.3.C scope). Honest admin generates ≤ 1 rotation per removal event → ≤ 20 rotations за rolling 24h is generous.

---

## 7. Error semantics

Reuse existing `LeafError.relayUnreachable(reason:)` across все 5xx + transport + parsing failures (mirror invite). New `LeafError.rotationRequestRejected(reason:)` mirrors `inviteRequestRejected` pattern — 4xx surfaces caller-actionable bad-input/size/method/media-type variants. Reason strings:

- `"bad-input"` — 400; covers все validation failures relay'я (peer can't distinguish — relay logs detail, client sees generic).
- `"method"` — 405.
- `"size"` — 413.
- `"media-type"` — 415.

Caller (5.3.D `KeyRotationService`) для `bad-input` should treat as bug-in-our-code (мы compose'или blob, мы its size/shape control'им) — surface как unrecoverable error, not retryable transport. `.relayUnreachable` → retry per RotationOutbox resume.

---

## 8. Contract amendment

Edit `docs/superpowers/specs/2026-05-04-phase-5-architecture-contract.md`:

### §8 — Phase 5.3 section (currently TBD, lines 211-213)

Replace placeholder со конкретным endpoint shape:

```markdown
### Phase 5.3 — key rotation endpoints

- `POST /v1/key-rotation` — admin POSTs wrapped teamKey (or tombstone) blob:
  - `peer_pubkey_hex` — recipient's X25519 public.
  - `blob` — admin-side AES-GCM wrap (rotation: under HKDF(ECDH(admin, peer), salt=newKeyID); tombstone: under prior teamKey).
  - `expires_at_ms` — server enforces ≤ 24h.
  - Idempotent на `(peer_pubkey_hex, new_key_id_hex)` composite (server peeks blob to extract `new_key_id` — exact byte offsets are moat) — repeat POST returns same `rotation_id`.
  - Returns: `{ rotation_id: <random URL-safe 32-byte>, expires_at_ms }`.
- `GET /v1/key-rotation/by-peer/:peer_pubkey_hex` — peer drains mailbox.
  - Returns: `{ rotations: [{ rotation_id, blob, expires_at_ms }, ...] }` (200, possibly empty array).
  - **Server does NOT delete on GET** (list-then-ACK semantic, survives mid-install crash).
  - Cap N=20 на response array (defensive).
- `DELETE /v1/key-rotation/:rotation_id` — peer ACKs after successful unwrap+install. Idempotent 204 regardless of token shape / existence (existence-hiding mirror invite DELETE).

Storage layer: Cloudflare Workers KV (separate `KEY_ROTATIONS` namespace) с per-token TTL ≤ 24h. Idempotency через composite-key primary index `rot:<peer>:<newkid>` + reverse `rot-id:<rotation_id>` для DELETE lookup.
```

### §9 row 5.3 — promote TBD к concrete

Replace `(TBD) revocation endpoint or DO key-flush instruction` с:

```
`POST /v1/key-rotation`, `GET /v1/key-rotation/by-peer/:peer`, `DELETE /v1/key-rotation/:id` + KV `KEY_ROTATIONS` namespace
```

Single contract amendment commit (Stage 5 step #4 в plan).

---

## 9. Acceptance

**Per CommandUnit-level:**
- `swift test --package-path Packages/LeafCore` — все cases pass; numerical Δ +18-22 на baseline 852 → expected 870-874.
- `xcodebuild -scheme Leaf` / `LeafAgent` / `LeafMCP` / `LeafCore` / `LeafCorePrivate` — все BUILD SUCCEEDED.
- `cd ~/Desktop/Leaf/leaf-relay && npm test` — Vitest green локально.
- Contract amendment lands в same commit как RelayClient methods (или separate, see plan).

**Manual ship-gate (юзер runs):**
- `cd ~/Desktop/Leaf/leaf-relay && wrangler kv namespace create KEY_ROTATIONS` — capture id, paste в wrangler.toml.
- `wrangler deploy` — push live to `oauth.gundem.tech`.
- `curl -X POST https://oauth.gundem.tech/v1/key-rotation ...` smoke (sample valid + sample 400) — confirms route wired.
- Live curl GET drain on test peer pubkey returns 200 empty array.

Manual smoke — Stage 7 gate per 5.2.C precedent. Не block merge of leaf branch; gates leaf-relay deploy.

---

## 10. Forward-compat hand-off для 5.3.D / 5.3.E

### 5.3.D (admin orchestrator) hand-off

`KeyRotationService.rotate(...)` calls `relayClient.postRotationBlob(peerPubkeyHex:, blob:, expiresAtMs:)` per peer:
- Iterate remaining peers → wrap newTeamKey under per-peer ECDH → POST.
- Per removed peer → wrap tombstone under prior teamKey → POST.

Relay idempotency means `RotationOutbox` resume after crash safely retries POSTs — same `(peer, new_key_id)` returns same `rotation_id`, no duplicate rotation flooded into peer's mailbox.

### 5.3.E (peer fetch loop) hand-off

`RotationFetchService.tick()`:
1. `relayClient.fetchPendingRotations(forPeerPubkeyHex: self_pubkey_hex)` → `[RotationFetched]`.
2. For each item: `RotationBlobHeader.peek(from: blob)` → derive wrap key (ECDH or prior teamKey lookup) → `rotationCodec.decode(blob, wrapKey)` → discriminate `.rotation` / `.tombstone`.
3. On `.rotation` success: `database.insertTeamKey(...)` (handle ON CONFLICT — see invariant note below) + `database.deprecateTeamKey(prior_key_id)` + `keystore.writeTeamKey(...)`.
4. On `.tombstone` success: set `OrgReader.removedFromOrg = true` flag.
5. On any success path: `relayClient.ackRotation(rotationID:)`.

**Invariant note для 5.3.E:** `Database.insertTeamKey` is **strict INSERT** per 5.1.B contract. На duplicate `id` (idempotent re-fetch case) it throws `LeafError.databaseAvailable`-like error. **5.3.E must wrap insertTeamKey call in try/catch** treating duplicate-id throw как success (idempotent install — peer fetches twice, second install no-op). Alternative: 5.3.E adds `Database.insertTeamKeyIfAbsent(...)` helper (additive 5.1.B extension). Decision deferred to 5.3.E spec.

**Why this matters now:** 5.3.C wire layer makes mid-install crash possible (peer fetches → unwraps → `insertTeamKey` succeeds → before `ackRotation`, app crashes → on relaunch, drain returns same blob → second `insertTeamKey` fails). Without 5.3.E handling, peer is permanently stuck. **Flag в 5.3.E spec write — not 5.3.C concern.**

---

## 11. Whitepaper sync

Implementation moat (KV key prefix scheme, 4KB/2KB raw/blob limits, MAX_PENDING_PER_PEER cap, dedup composite key derivation byte offsets) — НЕ surfaces в whitepaper. Public-safe surface (endpoint shapes + idempotent semantics + list-then-ACK) — already в architecture contract amendment §8.

Changelog entry в `~/Desktop/Leaf/leaf-docs/docs/05-reference/changelog.md` — defer до Phase 5.3 ship'а в alpha.X (5.3.E ship-gate), pattern consistent с 5.1.A-E, 5.2.A-E, 5.3.A, 5.3.B.

---

## 12. Out of scope (явный won't-list для 5.3.C)

| Scope | Why | Reserved for |
|---|---|---|
| Rate limiting per IP / pubkey | Honest admin generates ≤ 20 rotations per 24h naturally; cap + TTL adequate | Ops-level если abuse surfaces в alpha |
| Authentication beyond pubkey-as-bearer | Capability model match invite precedent + envelope crypto upholds confidentiality | Phase 5.x cold-start re-keying если threat model changes |
| Server-side blob signature verification | Relay = honest-but-curious; tag-validate peer-side | n/a |
| Bulk DELETE endpoint | Premature optimization; drain → per-item ACK simple | 5.4 if traffic measurements warrant |
| Wrangler deploy automation / CI hook | leaf-relay репо housekeeping carry-over from current-state | Separate ops phase |
| `KeyRotationService` admin orchestrator | First caller of wire methods | 5.3.D |
| `RotationFetchService` peer loop | Peer-side flow consumer | 5.3.E |
| `RotationOutbox` write-ahead journal | Crash-recovery layer над wire | 5.3.D |
| UI: TeamView per-row "Remove…" + RemovedFromTeamBanner | Top-of-stack UX | 5.3.E |
| Composition root wiring (`#if LEAF_PROD`) для rotation flow | First consumers ещё не существуют | 5.3.D / 5.3.E |
