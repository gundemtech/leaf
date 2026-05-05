# Phase 5.2.C — `leaf-oauth-relay` invite endpoints (POST/GET/DELETE `/v1/invite` + KV)

**Status:** Active (2026-05-05). Third sub-phase of Phase 5.2 ("relay invite endpoints + invite UX + ECDH handshake").
**Owner:** Dmitrii.
**Stack:** branches off `feature/phase-5-2-B` for spec commit; implementation lives in separate private repo `gundemtech/leaf-relay` on branch `feature/v1-invite` off its own `main`.

---

## 1. Context

Phase 5.2.A landed 5 commits в `leaf` repo — substrate под invite handshake (X25519 ECDH wrapper + HKDF-SHA256 + `IdentityService.ensureLocalIdentity`). Phase 5.2.B landed 4 commits — `InviteBlob` value type + `ProdInviteBlobCodec` AES-GCM-256 wrap'er. На-disk admin теперь умеет собрать opaque `[ver:1B|admin_pubkey:32B|nonce:12B|ciphertext|tag:16B]` blob с обёрнутым team_key для invitee'я. Без wire layer этот blob некуда отправить.

**Зачем 5.2.C сейчас:** decomposition spec §3 заkey'ил wire layer как "leaf-oauth-relay extension: POST /v1/invite, GET /v1/invite/:token, DELETE /v1/invite/:token + KV namespace + Vitest + wrangler deploy". 5.2.D (Swift `RelayClient` + admin orchestrator + generate-invite UI) и 5.2.E (invitee accept-flow + E2E test) **зависят от живого endpoint'а** на `oauth.gundem.tech/v1/invite/*`. Без него 5.2.D testing требует stub'а вместо real network round-trip + 5.2.E E2E test невозможен.

**Контрактные инварианты, которые 5.2.C не трогает:**

- **§3 boundary rule** — relay holds **ephemeral only** state (TTL'd invite KV); никакой долгосрочный ownership. Phase 5.2.C добавляет KV namespace `INVITES` — единственный оправданный state на relay (см. §6 этого spec'а).
- **§5 trust model** — relay = honest-but-curious; видит только opaque encrypted blobs. 5.2.C принимает blob bytes от admin, отдаёт invitee, никогда не decryptит.
- **§8 versioning policy** — все Phase 5 endpoints под `/v1/` prefix. `/slack/callback` (Phase 4.4) остаётся version-less (existing path).
- **Capability tokens are bearers** — relay не валидирует identity, доверяет владению token'ом. Invariant из §8 матчится с decomp §4.2 wire format.

Существующий Slack OAuth bouncer (Phase 4.4, live на `oauth.gundem.tech/slack/callback`) **не меняет behavior** — handler извлекается as-is в `src/oauth.ts`, его тесты остаются зелёными без правок (regression check для split refactor'а).

---

## 2. Sources of truth (priority при противоречии)

1. `2026-05-04-phase-5-architecture-contract.md` — §3 (repo split rules), §5 (trust model), §8 (relay API surface), §10 (failure modes).
2. `2026-05-04-phase-5-2-decomposition.md` — §3 (sub-phase scope locked), §4.2 (wire format locked: status codes + JSON shapes + headers), §4.5 (consumer-side `RelayClient` Swift signature — 5.2.D will implement against this surface — служит как "consumer-test" того что 5.2.C публикует), §6 (verification gate), §8 (risks).
3. `~/Desktop/Leaf/leaf-relay/CLAUDE.md` — relay coding rules (no query-string logging, `Cache-Control: no-store` everywhere, whitelist params).
4. `~/Desktop/Leaf/leaf-relay/src/index.ts` + `tests/relay.test.ts` — code-style precedent (hand-rolled fetch handler, `console.warn` only).
5. Cloudflare Workers KV docs (`developers.cloudflare.com/kv/api/`) — `expirationTtl` semantics, `cacheTtl: 0` for stale-bypass, list/get/put/delete behaviour.

---

## 3. Scope

### Входит

| Артефакт | Файл | Заметка |
|---|---|---|
| Shared response headers | `src/lib/headers.ts` (новый) | `NO_STORE_HEADERS` const hoisted из `index.ts` |
| Encoding helpers + token gen | `src/lib/encoding.ts` (новый) | `base64urlEncode(Uint8Array)`, `base64urlDecode(string)`, `isHex64(string)`, `randomToken32()` |
| Encoding lib tests | `tests/encoding.test.ts` (новый) | 4-6 tests: round-trip / pad-stripping / invalid-charset / hex regex / token shape (32 chars + alphabet + uniqueness across N=100 calls) |
| Slack OAuth handler extraction | `src/oauth.ts` (новый) | Existing handler verbatim — pure refactor |
| Router shell + Env type | `src/index.ts` (rewrite) | Method+path dispatcher; `interface Env { INVITES: KVNamespace }`; `ExportedHandler<Env>` |
| `wrangler.toml` updates | `src/wrangler.toml` (edit) | Fold uncommitted hostname-only `pattern` fix + `[[kv_namespaces]]` block (placeholder IDs до Step 12) |
| Invite handlers | `src/invite.ts` (новый) | POST + GET + DELETE under `/v1/invite/*` |
| Invite handler tests | `tests/invite.test.ts` (новый) | ≥14 tests covering all wire-format rows из §4 + KV semantics + error paths |
| README route table | `README.md` (edit) | Section "Phase 5.2 — invite endpoints" + curl smoke + Layout tree update |
| CLAUDE.md exception | `CLAUDE.md` (edit) | Append "Exception (Phase 5.2.C)" под rule 2 — KV namespace justification |

### НЕ входит (явно отложено)

- **`RelayClient` Swift wire client** (URLSession + JSON encode/decode + error mapping) — 5.2.D.
- **`InviteService` admin orchestrator** (gen OTP → wrap blob via `ProdInviteBlobCodec` → POST → display token+OTP) — 5.2.D.
- **Generate-invite UI** (`+ Add member` sheet в TeamView) — 5.2.D.
- **`InviteAcceptService` invitee orchestrator** + **Accept-invite UI** (modal/sheet) + **Onboarding screen 6 partial** — 5.2.E.
- **Two-Mac E2E integration test** (full handshake admin↔invitee локально через URLProtocol stub) — 5.2.E.
- **Worker rename** `leaf-oauth-relay` → `leaf-relay` (cosmetic) — отдельный chore-PR future.
- **GH Actions auto-deploy** — per leaf-relay CLAUDE.md "Что НЕ делать"; explicit user request needed.
- **KV propagation latency mitigation в admin UI** ("ready in ~30s" hint) — 5.2.D app-layer UX.
- **Per-IP rate limiting на POST** — Cloudflare DDoS + cost ceiling sufficient в MVP; explicit limit на v1.1+ if abuse observed.
- **Whitepaper sync** — `presence-relay.md` уже описывает invite flow абстрактно. Public-truth update — Phase 5.2 end-of-track при 5.2.E ship.

---

## 4. Wire format (locked from decomposition spec §4.2)

### 4.1 `POST /v1/invite`

**Request** (Content-Type: application/json):

```jsonc
{
  "member_pubkey_hex": "<64 chars hex>",   // invitee's X25519 pubkey, lower- or upper-case hex accepted
  "blob": "<base64url no-pad>",             // wrapped invite blob bytes (≤ 8192 bytes decoded)
  "expires_at_ms": 1760000000000            // server enforces now ≤ x ≤ now+24h+60s skew
}
```

**Responses:**

| Status | When | Body |
|---|---|---|
| **201** | All validation passed; KV.put succeeded | `{ "token": "<base64url 32 chars>", "expires_at_ms": 1760000000000 }` |
| **400** | JSON parse fail / missing field / `member_pubkey_hex` not 64-hex / `blob` not base64url / `expires_at_ms` not integer / out-of-bounds | (no body) |
| **413** | Raw request body > 12 KB OR decoded blob > 8192 bytes | (no body) |
| **415** | `Content-Type` does not start with `application/json` | (no body) |
| **405** | Method != POST | `Allow: POST` header |

### 4.2 `GET /v1/invite/:token`

**Path parameter:** `token` matches `^[A-Za-z0-9_-]{32}$`. Mismatch → 404 (uniform with consumed/expired).

**Responses:**

| Status | When | Body |
|---|---|---|
| **200** | Token exists in KV; KV.delete succeeded before reply | `{ "blob": "<base64url>", "expires_at_ms": 1760000000000 }` |
| **404** | Token consumed / expired / never existed / malformed-token-shape (indistinguishable) | (no body) |
| **500** | KV.delete failure between get-200 and reply | (no body — server-side log only) |
| **405** | Method != GET | `Allow: GET, DELETE` header |

**One-shot semantics:** `KV.get` (with `cacheTtl: 0` to bypass edge cache during the ~60s eventual-consistency window) → if null → 404. Else `await KV.delete(token)` → return 200. **delete-before-respond** invariant: if delete throws, 500 (don't ship blob if we can't mark consumed).

### 4.3 `DELETE /v1/invite/:token`

**Always 204.** Идempotent; never reveals existence (matches consumed/expired/never-existed). Malformed-token shape also 204 (uniform existence-hiding). Internally `await KV.delete(token)` for log visibility; KV.delete is no-op on missing keys per CF KV spec.

| Status | When |
|---|---|
| **204** | Always (after token-format validation pass-through) |
| **405** | Method != DELETE | `Allow: GET, DELETE` header |

### 4.4 Token format

24 random bytes via `crypto.getRandomValues(new Uint8Array(24))` → base64url no-pad → 32 chars matching `^[A-Za-z0-9_-]{32}$`.

### 4.5 Cache headers

Every response carries `NO_STORE_HEADERS` (existing const for OAuth handler — hoisted to `lib/headers.ts`):

```
Cache-Control: no-store, no-cache, must-revalidate
Pragma: no-cache
```

JSON-body responses additionally carry `Content-Type: application/json`.

---

## 5. Validation order (POST `/v1/invite`)

Fail-fast, cheapest-first. Each step rejects and short-circuits before incurring next step's cost.

| # | Check | Failure status | Failure log |
|---|---|---|---|
| 1 | `request.method === "POST"` | 405 | `405 invite-method-not-allowed` |
| 2 | `Content-Type` starts with `application/json` | 415 | `415 invite-bad-content-type` |
| 3 | `await request.text()` byte length ≤ 12288 (12 KB) | 413 | `413 invite-raw-too-large` |
| 4 | `JSON.parse(text)` succeeds | 400 | `400 invite-bad-json` |
| 5 | Top-level object has all 3 fields (`member_pubkey_hex`, `blob`, `expires_at_ms`) | 400 | `400 invite-missing-field` |
| 6 | `isHex64(member_pubkey_hex)` (i.e. matches `^[0-9a-fA-F]{64}$`) | 400 | `400 invite-bad-pubkey` |
| 7 | `blob` matches base64url alphabet `^[A-Za-z0-9_-]+$` (no pad chars accepted) | 400 | `400 invite-bad-blob-charset` |
| 8 | `base64urlDecode(blob).byteLength` ≤ 8192 | 413 | `413 invite-blob-too-large` |
| 9 | `Number.isInteger(expires_at_ms) && Date.now() ≤ expires_at_ms ≤ Date.now() + 24*60*60*1000 + 60*1000` | 400 | `400 invite-bad-expiry` |
| 10 | `randomToken32()` + `KV.put(token, JSON.stringify({member_pubkey_hex, blob_b64: blob, expires_at_ms}), { expirationTtl })` succeeds | 500 (uncaught surface) | `500 invite-kv-put-failed` |

`expirationTtl` formula: `Math.max(60, Math.floor((expires_at_ms - Date.now()) / 1000))`. CF KV minimum TTL = 60s.

**12 KB raw ceiling** vs **8 KB blob ceiling**: JSON envelope (`member_pubkey_hex` 64 + `blob` base64url-overhead-of-binary ≈ 4/3 × 8192 ≈ 10923 + `expires_at_ms` 13 + JSON syntax ≈ 100) → ~11140 bytes worst-case. 12288 leaves safety margin while still catching hostile encoded inflation.

**Hex case acceptance:** `isHex64` regex permits both upper and lower hex digits to match `LeafCore` `KeyAgreement.sharedSecret(privateKey:peerPublicKeyHex:)` lenient-decode пolitика (validated in 5.2.A). Storage normalises to lower-case before KV.put — invitee never observes non-canonical form.

---

## 6. KV namespace `INVITES`

### 6.1 Justification (relay architecture contract §3 boundary rule)

Per contract §3: relay holds "**ephemeral only — TTL'd invite KV**" state. Persistent ownership of org/member metadata stays на каждом устройстве (SQLCipher); relay's only mutable state is short-lived encrypted invite blobs that get auto-purged.

KV is the lightest-weight Workers persistent primitive that supports server-side TTL. Alternatives considered + rejected:

- **Durable Object** — overkill for fire-and-forget invite storage; per-invite DO would explode count + cost. DOs are reserved for Phase 5.4 per-team presence broadcast where stateful WebSocket session is justified.
- **D1 (SQLite)** — TTL not native; would require cron-triggered cleanup; SQL surface unwarranted for KV-shaped access pattern.
- **R2** — object storage, no TTL native; same cleanup overhead; latency higher.

KV provides: native `expirationTtl` (server-side auto-purge), get/put/delete by string key, eventual consistency 60s-typical (acknowledged in §8 risks below).

### 6.2 wrangler.toml shape (post Step 4)

```toml
[[kv_namespaces]]
binding = "INVITES"
id = "<production-id>"          # filled at deploy step (Step 12)
preview_id = "<preview-id>"     # filled at deploy step
```

### 6.3 Test integration

`@cloudflare/vitest-pool-workers` (already configured in `vitest.config.ts`) spins **isolated in-memory KV per test** automatically when binding declared in `wrangler.toml`. No production namespace ID needed for `npm test` to pass — placeholder strings are sufficient until Step 12 deploy.

### 6.4 Production deploy flow (Step 12)

```bash
npx wrangler kv namespace create INVITES            # → id = "<hex>"
npx wrangler kv namespace create INVITES --preview  # → preview_id = "<hex>"
# Patch wrangler.toml inline-replace placeholders.
npx wrangler deploy
```

KV namespace IDs are not secrets but treated as deploy-time config (commit on deploy step, not before).

---

## 7. File / module layout

### Pre-5.2.C (current)

```
leaf-relay/
├── src/
│   └── index.ts            # ~50 LOC OAuth handler (one fetch handler)
├── tests/
│   └── relay.test.ts       # 8 OAuth tests
├── wrangler.toml
├── vitest.config.ts
├── tsconfig.json
├── package.json
├── CLAUDE.md
└── README.md
```

### Post-5.2.C

```
leaf-relay/
├── src/
│   ├── index.ts            # ~30 LOC router shell — dispatches by method+path
│   ├── oauth.ts            # GET /slack/callback (extracted verbatim from index.ts)
│   ├── invite.ts           # POST/GET/DELETE /v1/invite/* + KV access
│   └── lib/
│       ├── headers.ts      # NO_STORE_HEADERS const
│       └── encoding.ts     # base64urlEncode/Decode, isHex64, randomToken32
├── tests/
│   ├── relay.test.ts       # 8 OAuth tests (untouched)
│   ├── invite.test.ts      # ≥14 invite handler tests
│   └── encoding.test.ts    # 4-6 lib tests
├── wrangler.toml           # + [[kv_namespaces]] INVITES + canonical custom_domain pattern
├── vitest.config.ts        # untouched
├── tsconfig.json           # untouched
├── package.json            # untouched
├── CLAUDE.md               # + KV exception under rule 2
└── README.md               # + Phase 5.2 routes section
```

---

## 8. Sub-phase decomposition (TDD per step)

| Step | Repo | Files | Test gate | Commit message |
|---|---|---|---|---|
| **1** | `leaf` (this) | `docs/superpowers/specs/2026-05-04-phase-5-2-C-relay-invite.md` (this file) | — | `docs(specs): Phase 5.2.C — leaf-oauth-relay invite endpoints spec` |
| **2** | `leaf-relay` | `src/lib/headers.ts` + `src/lib/encoding.ts` + `tests/encoding.test.ts` | `npm test` green; `index.ts` continues to use new helpers | `feat(lib): encoding + headers helpers` |
| **3** | `leaf-relay` | `src/oauth.ts` (extract) + `src/index.ts` (router shell) | `npm test` green — all 8 OAuth tests pass with extraction | `refactor(router): split OAuth handler from index` |
| **4** | `leaf-relay` | `wrangler.toml` (canonical pattern + `[[kv_namespaces]]`) + `src/index.ts` (Env interface + `ExportedHandler<Env>`) | `tsc` clean; `npm test` green (in-memory KV) | `chore(wrangler): canonical custom_domain pattern + INVITES KV binding` |
| **5+6** | `leaf-relay` | `tests/invite.test.ts` (POST tests ~7-8) + `src/invite.ts` POST handler + router wire | POST tests RED → GREEN; OAuth + encoding still GREEN | `feat(invite): POST /v1/invite handler` |
| **7+8** | `leaf-relay` | `tests/invite.test.ts` (extend +5 GET) + `src/invite.ts` GET handler | GET tests RED → GREEN | `feat(invite): GET /v1/invite/:token one-shot consume` |
| **9+10** | `leaf-relay` | `tests/invite.test.ts` (extend +3 DELETE) + `src/invite.ts` DELETE handler | DELETE tests RED → GREEN; full suite ≥18 GREEN | `feat(invite): DELETE /v1/invite/:token` |
| **11** | `leaf-relay` | `README.md` + `CLAUDE.md` | docs only | `docs(relay): Phase 5.2.C — invite endpoints documentation` |
| **12** | `leaf-relay` | `wrangler.toml` (real KV IDs) + `wrangler deploy` + curl smoke | curl smoke green | `chore(deploy): real INVITES KV namespace IDs + production deploy` |

**Implementation discipline (Stage 5 of conventions §"Одна phase = одна сессия"):** TDD per step — test red → impl → green → commit. Steps 5+6, 7+8, 9+10 paired (test commit folded with impl commit per conventions; bare-test-commit is anti-pattern when impl follows immediately).

---

## 9. Test target ≥18

| Suite | File | Count | Coverage |
|---|---|---|---|
| OAuth (existing) | `tests/relay.test.ts` | 8 | untouched — regression check that refactor (Step 3) does not break |
| Encoding lib | `tests/encoding.test.ts` | 4-6 | base64url round-trip / pad-strip-on-encode / invalid-charset reject / hex64 regex pass+fail / token shape (32 chars, alphabet) / token uniqueness (N=100) |
| Invite POST | `tests/invite.test.ts` § POST | ~8 | valid 201 + token shape / KV stored value (round-trip via direct KV.get in test) / missing field 400 / bad pubkey 400 (wrong length, non-hex) / bad blob charset 400 / blob > 8KB 413 / raw > 12KB 413 / non-JSON CT 415 / expires_at past 400 / expires_at > now+24h+60s 400 / wrong method (GET on POST) 405 |
| Invite GET | `tests/invite.test.ts` § GET | ~5 | first-call 200 + correct blob+expires / KV deleted after consume (verify via direct KV.get → null) / second-call 404 / nonexistent 404 / malformed-token-charset 404 |
| Invite DELETE | `tests/invite.test.ts` § DELETE | ~3 | delete-then-get 404 / delete-nonexistent 204 / malformed-token 204 |
| **Total** | | **~28** | exceeds ≥18 target |

**Test patterns** (mirror existing `relay.test.ts`):

- `import { SELF, env } from "cloudflare:test"` — `env.INVITES` exposed for KV inspection in tests.
- `SELF.fetch(...)` for HTTP round-trip; `redirect: "manual"` где relevant.
- Status assertions + header presence (`Cache-Control: no-store`).
- KV inspection в tests: `await env.INVITES.get(token)` — verifies internal storage matches wire shape.

---

## 10. Logging discipline

Mirror existing OAuth handler — `console.warn(STATUS LABEL)` only, never log token / blob / pubkey_hex / body / query string.

Exact log strings:

| Status | Label |
|---|---|
| 201 | `201 invite-created` |
| 200 | `200 invite-consumed` |
| 204 | `204 invite-deleted` |
| 400 | `400 invite-bad-json`, `400 invite-missing-field`, `400 invite-bad-pubkey`, `400 invite-bad-blob-charset`, `400 invite-bad-expiry` |
| 404 | `404 invite-not-found` |
| 405 | `405 invite-method-not-allowed` |
| 413 | `413 invite-raw-too-large`, `413 invite-blob-too-large` |
| 415 | `415 invite-bad-content-type` |
| 500 | `500 invite-kv-put-failed`, `500 invite-kv-delete-failed` |

Code review (Stage 6) explicitly checks that no logger call captures user input.

---

## 11. CLAUDE.md update (leaf-relay)

Existing rule 2 in `~/Desktop/Leaf/leaf-relay/CLAUDE.md`:

> 2. **Worker stateless.** Никаких `[[d1_databases]]`, `[[kv_namespaces]]`, `[vars]` в `wrangler.toml` без явного обоснования. Если задача требует state — обсуди с юзером.

Append (not replace):

> **Exception (Phase 5.2.C, 2026-05-05):** `INVITES` KV namespace — ephemeral 24h-TTL'd invite blobs, opaque encrypted bytes only. Justification — per relay architecture contract §3 boundary rule ("ephemeral only — TTL'd invite KV") и contract §5 trust model ("relay sees only opaque encrypted blobs"). All other state additions still require explicit user approval.

---

## 12. Verification gate (Step 12)

```bash
cd ~/Desktop/Leaf/leaf-relay
npm test                                    # ≥18 pass

# Pre-deploy KV namespace creation (one-time per env)
npx wrangler kv namespace create INVITES
npx wrangler kv namespace create INVITES --preview
# → copy IDs into wrangler.toml [[kv_namespaces]]

npx wrangler deploy

# Live smoke
curl -i 'https://oauth.gundem.tech/v1/invite/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'  # 404 + no-store
curl -i -X DELETE 'https://oauth.gundem.tech/v1/invite/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'  # 204
PUBKEY=$(printf 'a%.0s' {1..64})
EXP_MS=$(( $(date +%s%N) / 1000000 + 3600000 ))
curl -i -X POST 'https://oauth.gundem.tech/v1/invite' \
  -H 'Content-Type: application/json' \
  -d "{\"member_pubkey_hex\":\"$PUBKEY\",\"blob\":\"AAAA\",\"expires_at_ms\":$EXP_MS}"
# → 201 + { token: "<32 chars>", expires_at_ms: ... }

# Existing OAuth path still live (regression)
curl -i 'https://oauth.gundem.tech/slack/callback?code=test&state=abc'  # 302 to loopback
```

Two-Mac E2E gate (admin↔invitee real handshake) — **5.2.E** scope, не 5.2.C.

---

## 13. Risks + mitigations

| Risk | Mitigation |
|---|---|
| KV global eventual consistency (~60s prop) — admin POST → invitee immediate GET could 404 | C5 GET handler uses `cacheTtl: 0` to bypass edge cache. Invitee-side retry on initial 404 — 5.2.E concern. Worst case admin re-shares token; not a security issue (token still bounded by 24h TTL + one-shot). |
| `crypto.getRandomValues` on Workers — uses CSPRNG per spec, but documented assumption | Encoding lib test asserts 32-char output + uniqueness across N=100 calls. Production trust = same baseline as nonce generation в `ProdInviteBlobCodec` (already shipped в 5.2.B). |
| Validation order skip — bug: 8KB ceiling check after JSON parse means raw 12 KB body memory-cost incurred before reject | §5 puts `request.text()` size limit **before** JSON.parse (step 3 of validation). Workers default 100 KB body limit → safe upper bound. |
| `KV.delete` failure between get-200 and reply → invitee gets blob but key still claimable | §4.2 awaits delete before returning 200; failure surfaces as 500. Token still bounded by TTL + one-shot UX flow tolerates duplicate attempts. |
| Test pool-workers KV namespace mismatch with prod | Vitest `cloudflare:test` pool spins isolated in-memory KV per test based on `wrangler.toml` binding declaration; placeholder IDs sufficient until Step 12. |
| Uncommitted `wrangler.toml` change current diff (`oauth.gundem.tech/*` → `oauth.gundem.tech`) — folded into Step 4 commit | Step 4 explicitly stages only the two intended changes (pattern fix + KV block); user reviews diff before commit. CF docs verified hostname-only канон для `custom_domain = true`. |
| `console.warn` over-logs and accidentally captures sensitive arg | §10 enumerates exact log strings. Code review (Stage 6) explicitly checks logger calls. |
| Worker name `leaf-oauth-relay` becoming misleading after Phase 5.2 (handles both OAuth + invite) | Cosmetic. Defer rename to separate chore-PR per decomposition spec §7 row "Cosmetic worker rename". |

---

## 14. Out of scope (deferred)

| Excluded | Why | Reserved for |
|---|---|---|
| Swift `RelayClient` HTTP wire client | leaf-side consumer | 5.2.D |
| `InviteService` admin orchestrator (gen OTP → wrap blob → POST → display) | Domain layer | 5.2.D |
| Generate-invite UI (`+ Add member` sheet в TeamView, copy-pubkey + copy-token+OTP buttons) | App layer | 5.2.D |
| `InviteAcceptService` invitee orchestrator (fetch → unwrap with OTP → materialize rows) | Invitee orchestrator | 5.2.E |
| Accept-invite UI (modal/sheet) + Onboarding screen 6 partial + OrganizationView empty-state second CTA | App layer | 5.2.E |
| Two-Mac E2E integration test | Requires both admin & invitee orchestrators | 5.2.E |
| Worker rename `leaf-oauth-relay` → `leaf-relay` | Cosmetic | future chore-PR |
| GH Actions auto-deploy | Per leaf-relay CLAUDE.md "Что НЕ делать" — explicit user request needed | future |
| Per-IP rate limiting on POST | CF DDoS + cost ceiling sufficient в MVP | v1.1+ if abuse observed |
| Whitepaper sync (`presence-relay.md` already abstract) | Public-truth update timed at end-of-track ship | 5.2.E ship |

---

## 15. Critical files to read before each step

| File | Why |
|---|---|
| `2026-05-04-phase-5-2-decomposition.md` §4.2-§4.5, §8 | Wire format invariants; risks |
| `2026-05-04-phase-5-architecture-contract.md` §3, §5, §8, §10 | Repo boundary, trust model, API surface, failure modes |
| `~/Desktop/Leaf/leaf-relay/src/index.ts` | Code style precedent (handler shape, headers, logging) |
| `~/Desktop/Leaf/leaf-relay/tests/relay.test.ts` | Test style precedent (`SELF.fetch` from `cloudflare:test`, status assertions, redirect handling) |
| `~/Desktop/Leaf/leaf-relay/CLAUDE.md` | Relay-specific rules (no query logging, no-store, KV exception додаток) |
| `~/Desktop/Leaf/leaf-relay/wrangler.toml` | KV binding insertion target |
| `~/Desktop/Leaf/leaf/docs/superpowers/specs/2026-05-04-phase-5-2-B-invite-blob.md` | Sister-phase spec format precedent |
| Cloudflare Workers KV docs (`developers.cloudflare.com/kv/api/`) | `expirationTtl`, `cacheTtl: 0`, get/put/delete semantics |
| `@cloudflare/vitest-pool-workers` docs | `cloudflare:test` SELF + `env` bindings access in tests |

---

*End of 5.2.C spec. After ship, follow-up sub-phases 5.2.D (admin Swift orchestrator + UI) и 5.2.E (invitee orchestrator + E2E) execute against the live `oauth.gundem.tech/v1/invite/*` endpoints.*
