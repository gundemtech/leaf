# Server-side idempotency — `Idempotency-Key` header + `idempotency_log` table

**Status:** Draft (2026-05-22). Phase M-II from `optimization-tier-m.md`.
**Owner:** Local Claude (Mac) + VPS Claude (server deploy).
**Branch:** `feature/invite-redesign` (M-II lands as separate commit chain on top of M-I + M-III, parallel-but-after the dirty WIP wrapup).
**Cross-reference:**
- `.claude/plans/optimization-tier-m.md` — audit punch list (M-II row).
- M-I spec — `docs/superpowers/specs/2026-05-22-supabase-with-retry-design.md` (provides `performHTTP` shim that M-II extends).
- M-III spec — `docs/superpowers/specs/2026-05-22-supabase-401-refresh-design.md` (orthogonal — both extend `performHTTP`).
- Track 5 / S3 + S4 + S6 + S7 + S8 — Edge Functions M-II instruments.
- Invite System Redesign — `docs/superpowers/specs/2026-05-20-invite-system-redesign-design.md` (the 6 join-request Edge Functions are M-II's primary client).

---

## 1. Goal — fitness function

M-II is **done** when:

1. **Network blip after server commit but before client sees 200** → client `performHTTP` retries silently and the second request hits the server's idempotency layer, which **replays the original response body** instead of mutating state twice. The user-visible behavior is identical to a clean first-shot success.
2. **`invite_tokens.used_count` does not over-increment** when the network blips during `create_join_request` between commit and ack. `join_requests` row is created exactly once per logical request.
3. **`decline_join_request` does not produce duplicate audit churn** when the network blips between commit and ack — replay returns the original "already declined" success body, not a 409.
4. **All 17 dedup-enabled client POST callsites** (targeting 16 distinct Edge Functions — `resolveInvite` and `probeInvite` both hit `invite_resolve`) can be flipped to `retryable: true` without risk of double-mutation. The M-I retry loop becomes safe for POST.
5. **Same-key + different-body retries return 422 `idempotency_key_mismatch`** — protects against client bugs reusing a key across distinct logical operations.
6. **Expired keys (>24h)** are pruned by a nightly cron — table does not grow without bound; replay is best-effort within a 24h window.
7. **Two UPSERT POSTs** (`registerAPNsToken`, `upsertNotificationPref`) flip to `retryable: true` **without** Idempotency-Key — they're naturally idempotent at DB level via `ON CONFLICT DO UPDATE`. M-II treats this as a documentation-only entry.
8. **Two Supabase Auth POSTs** (`signInAnonymously`, `performTokenRefresh`) stay `retryable: false` — third-party endpoints, non-idempotent by nature. M-II does not touch these.
9. **No public API changes** on `SupabaseClient` Swift surface — `Idempotency-Key` header is injected inside `performHTTP`; callers gain one new `idempotent: Bool` parameter through private transport helpers but external Swift consumers see the same method signatures and the same `SupabaseError` cases.
10. **No regressions** in 121 existing `SupabaseClient*Tests.swift` + 22 retry tests + 5 refresh tests; baseline preserved + ~25 net new idempotency tests (15 Swift integration + 10 Deno unit) + 6 net new pgTAP scenarios.

---

## 2. Architecture

### 2.1 Files

**New on `leaf-relay`** (1 migration + 1 shared module + 5 Edge Functions + 1 cron extension + tests):
- `supabase/migrations/20260604120000_m028_idempotency_log.sql` — `idempotency_log` table + RLS + indexes + (re-uses existing pg_cron extension).
- `supabase/migrations/20260604120100_m028_idempotency_prune_cron.sql` — nightly cron job calling `prune_idempotency_log()`.
- `supabase/functions/_shared/idempotency.ts` — middleware: `checkIdempotency()` + `saveIdempotencyResponse()`.
- `supabase/functions/insert_workspace/index.ts` + `test.ts` — wraps PostgREST `INSERT INTO workspaces`.
- `supabase/functions/insert_invite_token/index.ts` + `test.ts` — wraps `INSERT INTO invite_tokens`.
- `supabase/functions/insert_workspace_member/index.ts` + `test.ts` — wraps `INSERT INTO workspace_members`.
- `supabase/functions/send_team_event/index.ts` + `test.ts` — wraps `INSERT INTO team_events`.
- `supabase/functions/submit_waitlist/index.ts` + `test.ts` — wraps `INSERT INTO waitlist`.
- `supabase/tests/database/290_idempotency_log.test.sql` — pgTAP: table + columns + PK + RLS + prune function correctness.
- `supabase/tests/database/300_idempotency_cron.test.sql` — pgTAP: cron schedule entry exists.

**Modified on `leaf-relay`** (10 Edge Functions get middleware wired):
- `supabase/functions/{create,cancel,approve,decline}_join_request/index.ts` — add `checkIdempotency` before RPC call, `saveIdempotencyResponse` before final return.
- `supabase/functions/delete_invite_token/index.ts` — same.
- `supabase/functions/invite_resolve/index.ts` — same (anon flow; `owner_pubkey` may be NULL).
- `supabase/functions/register_pubkey/index.ts` — same (bootstrap flow; treats access_token bearer as owner).
- `supabase/functions/apns_push/index.ts` — same.
- `supabase/functions/slack_post/index.ts` — same.
- `supabase/functions/linear_create_issue/index.ts` — same; **delete the legacy `idempotency_key` body field** (replaced by header).

**New on `leaf`** (1 test file):
- `Packages/LeafCore/Tests/LeafCoreTests/SupabaseClientIdempotencyTests.swift` — 15 integration tests covering header injection, key-stable-across-retries, replay semantics observed from client, mismatch surface, UPSERT path untouched.

**Modified on `leaf`** (one shim file + 7 callsite files):
- `Packages/LeafCore/Sources/LeafCore/Network/SupabaseClient+Retry.swift` — extend `performHTTP` with `idempotent: Bool = false` param; when true, generate UUID v4 once outside the retry loop and inject `Idempotency-Key` header into the request copy.
- `Packages/LeafCore/Sources/LeafCore/Network/SupabaseClient.swift` — 2 callsites: `postInvite` (legacy invite path, kept for compat) + `performRegisterPubkey` (anon-bootstrap) gain `idempotent: true`. `insertWorkspaceMember` deleted (replaced by Edge call below).
- `Packages/LeafCore/Sources/LeafCore/Network/SupabaseClient+JoinRequests.swift` — 5 invoke* callsites flip to `retryable: true, idempotent: true`.
- `Packages/LeafCore/Sources/LeafCore/Network/SupabaseClient+InviteTokens.swift` — `insertInviteToken` rewrites to Edge call `insert_invite_token`; new signature, new endpoint, `retryable: true, idempotent: true`.
- `Packages/LeafCore/Sources/LeafCore/Network/SupabaseClient+Workspaces.swift` — `insertWorkspace` rewrites to Edge call `insert_workspace`; `retryable: true, idempotent: true`. `insertWorkspaceMember` lifted from `SupabaseClient.swift` into this file and rewritten as Edge call to `insert_workspace_member` (consolidates two adjacent concerns).
- `Packages/LeafCore/Sources/LeafCore/Network/SupabaseClient+TeamEvents.swift` — `sendTeamEvent` rewrites to Edge call `send_team_event`; `retryable: true, idempotent: true`.
- `Packages/LeafCore/Sources/LeafCore/Network/SupabaseClient+Waitlist.swift` — `submitToWaitlist` rewrites to Edge call `submit_waitlist`; `retryable: true, idempotent: true`.
- `Packages/LeafCore/Sources/LeafCore/Network/SupabaseClient+DirectMessages.swift` — `sendDirectMessage` flips `retryable: true, idempotent: true`. `triggerAPNsPush` same. `registerAPNsToken` (UPSERT) flips `retryable: true, idempotent: false` — no key, DB-level dedup via `ON CONFLICT`.
- `Packages/LeafCore/Sources/LeafCore/Network/SupabaseClient+CrossPost.swift` — `triggerSlackPost` + `triggerLinearCreate` flip `retryable: true, idempotent: true`. **Remove `idempotency_key` body field from `triggerLinearCreate`** — header replaces it.
- `Packages/LeafCore/Sources/LeafCore/Network/SupabaseClient+NotificationPrefs.swift` — `upsertNotificationPref` (UPSERT) flips `retryable: true, idempotent: false`.
- `Packages/LeafCore/Sources/LeafCore/Network/SupabaseEndpoint.swift` — add 5 new Edge endpoint constants, remove 5 PostgREST endpoints (`insert_workspaces`, `insert_invite_tokens`, etc.).

**Untouched:**
- `SupabaseError.swift` — no new cases; mismatch surfaces as `.serverError(422)`, missing key surfaces as `.transport(reason:)`.
- `MockURLProtocol` — closure-based handler already flexible enough to script Idempotency-Key scenarios.
- M-I's `RetryPolicy` + `classify()` — unchanged. M-III's refresh path — unchanged.
- 2 Supabase Auth POSTs (`performSignInAnonymously`, `performTokenRefresh`).
- The 4 existing GET / PATCH callsites already covered by M-I.

### 2.2 Schema — `idempotency_log` (M028)

```sql
-- supabase/migrations/20260604120000_m028_idempotency_log.sql
CREATE TABLE idempotency_log (
  idempotency_key  uuid         NOT NULL,
  fn_name          text         NOT NULL,
  owner_pubkey     text         NULL,           -- NULL for anon flows (waitlist)
  request_hash     text         NOT NULL,       -- SHA-256 of body bytes, lowercase hex
  response_status  smallint     NOT NULL,
  response_body    jsonb        NOT NULL,
  created_at       timestamptz  NOT NULL DEFAULT now(),
  expires_at       timestamptz  NOT NULL DEFAULT now() + interval '24 hours',
  PRIMARY KEY (idempotency_key)
);

CREATE INDEX idx_idempotency_log_expires_at
  ON idempotency_log (expires_at);

-- RLS: only service_role can read/write. All Edge Functions run under
-- service_role per existing pattern, so RLS is defence-in-depth against
-- accidental PostgREST exposure.
ALTER TABLE idempotency_log ENABLE ROW LEVEL SECURITY;
-- (no policy = deny-all for anon + authenticated; service_role bypasses RLS)

CREATE OR REPLACE FUNCTION prune_idempotency_log() RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
  deleted integer;
BEGIN
  DELETE FROM idempotency_log WHERE expires_at < now();
  GET DIAGNOSTICS deleted = ROW_COUNT;
  RETURN deleted;
END;
$$;
```

```sql
-- supabase/migrations/20260604120100_m028_idempotency_prune_cron.sql
SELECT cron.schedule(
  'prune-idempotency-log',
  '17 3 * * *',                       -- 03:17 UTC daily — off-peak
  $$ SELECT prune_idempotency_log() $$
);
```

**Why PK = key alone (not composite with fn_name):**
- UUID v4 has 122 bits of entropy. Cross-function collision probability is negligible (<1e-30 at 10^9 keys/year).
- Single-column PK simplifies replay lookup: `SELECT ... WHERE idempotency_key = $1` — no fn_name parameter to thread through. Misroutes (client sends key generated for `slack_post` to `linear_create_issue`) trigger a `request_hash` mismatch → 422, surfaced as bug.

**Why `request_hash` not full body:**
- Smaller row footprint.
- Replay decision (`hit/miss/mismatch`) is binary — we only need to compare hashes, not diff bodies.
- Hash collision probability irrelevant given UUID-keyed lookup.

**Why `text` (hex) not `bytea`:**
- `supabase-js` serializes `bytea` as `\\x`-prefixed hex over PostgREST — round-trip introduces an extra encoding hop.
- Lowercase hex `text` is straightforward to compare in both Postgres (`request_hash = $1`) and TypeScript (string equality).
- 64 chars = 64 bytes per row; negligible overhead vs 32-byte raw bytea.

**Why `response_body jsonb` not text:**
- Postgres native; allows server-side inspection for debugging without parsing.
- All 15 Edge Functions return JSON; non-JSON responses are out of scope.

**Why 24h TTL:**
- M-I retry schedule max ~4.2s, M-III refresh single-shot. Realistic replay window: seconds, not hours.
- 24h chosen to absorb client-side restart / sleep / wake retries (user closes laptop mid-POST, retries on wake). Cron prune at 03:17 UTC keeps table small.
- After 24h, retry is treated as a fresh operation. Acceptable: by then the original POST either landed (DB shows the row) or the user is in a different session context.

### 2.3 Middleware contract — `_shared/idempotency.ts`

```ts
// supabase/functions/_shared/idempotency.ts
import { createClient } from "jsr:@supabase/supabase-js@2";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export interface IdempotencyMiss {
  replay: false;
  key: string;
  hash: Uint8Array;          // SHA-256 of canonicalized body
  save: (status: number, body: unknown) => Promise<void>;
}

export interface IdempotencyHit {
  replay: true;
  status: number;
  body: unknown;
}

export type IdempotencyResult = IdempotencyMiss | IdempotencyHit;

/// Mismatch / missing-key throw a Response (caller `return throw.response`).
export class IdempotencyError extends Error {
  constructor(public readonly response: Response) { super("idempotency_error"); }
}

/// Inspect the request, return either a `replay: true` hit (caller returns
/// `body` with `status`) or a `replay: false` miss (caller proceeds with
/// handler then calls `save(status, body)` before returning).
export async function checkIdempotency(
  req: Request,
  fnName: string,
  ownerPubkey: string | null,
  bodyBytes: Uint8Array,
): Promise<IdempotencyResult> {
  const keyHeader = req.headers.get("Idempotency-Key");
  if (!keyHeader || !UUID_RE.test(keyHeader)) {
    throw new IdempotencyError(
      new Response(JSON.stringify({ error: "missing_idempotency_key" }), {
        status: 400,
        headers: { "content-type": "application/json" },
      }),
    );
  }
  const key = keyHeader.toLowerCase();

  // Hash the body bytes. SHA-256 via WebCrypto.
  const hashBuf = await crypto.subtle.digest("SHA-256", bodyBytes);
  const hash = new Uint8Array(hashBuf);

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const hashHex = encodeHex(hash);

  const { data, error } = await supabase
    .from("idempotency_log")
    .select("request_hash, response_status, response_body, expires_at")
    .eq("idempotency_key", key)
    .maybeSingle();
  if (error) throw error;

  if (data) {
    // Expired rows are pruned by cron; in the race window where a stale row
    // exists but cron hasn't fired, treat as miss and let the upsert below
    // overwrite. (The PK ensures correctness — last writer wins for stale.)
    if (new Date(data.expires_at).getTime() < Date.now()) {
      // fall through to miss path with an "overwrite on save" semantic
    } else {
      if (data.request_hash !== hashHex) {
        throw new IdempotencyError(
          new Response(JSON.stringify({ error: "idempotency_key_mismatch" }), {
            status: 422,
            headers: { "content-type": "application/json" },
          }),
        );
      }
      return { replay: true, status: data.response_status, body: data.response_body };
    }
  }

  return {
    replay: false,
    key,
    hash,
    save: async (status, body) => {
      // Only persist 2xx and deterministic 4xx (caller decides; see §5).
      if (status >= 500) return;
      await supabase
        .from("idempotency_log")
        .upsert(
          {
            idempotency_key: key,
            fn_name: fnName,
            owner_pubkey: ownerPubkey,
            request_hash: hashHex,
            response_status: status,
            response_body: body,
            // created_at + expires_at use column defaults on first insert.
          },
          { onConflict: "idempotency_key" },
        );
    },
  };
}

// Trivial helpers — `encodeHex` = Array.from(bytes).map(b => b.toString(16).padStart(2, '0')).join('');
// `bytesEqual` = a.length === b.length && a.every((v, i) => v === b[i]);
// `decodeHex` only needed if we ever change column type back to bytea (currently unused).
```

**Usage pattern in each Edge Function:**

```ts
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  // Auth (existing).
  const authHeader = req.headers.get("Authorization") ?? "";
  // ... auth.getUser + extractPubkey ...

  // Read body bytes once for both hashing and JSON parse.
  const bodyBytes = new Uint8Array(await req.arrayBuffer());

  let idem: IdempotencyResult;
  try {
    idem = await checkIdempotency(req, "create_join_request", inviteePubkey, bodyBytes);
  } catch (e) {
    if (e instanceof IdempotencyError) return e.response;
    throw e;
  }
  if (idem.replay) {
    return new Response(JSON.stringify(idem.body), {
      status: idem.status,
      headers: { "content-type": "application/json" },
    });
  }

  // Parse + handler logic (existing).
  let body: { /* shape */ };
  try { body = JSON.parse(new TextDecoder().decode(bodyBytes)); }
  catch { return json({ error: "bad_payload" }, 400); }

  // ... handler runs RPC ...
  const responseBody = { request_id, /* ... */ };
  const responseStatus = 201;

  await idem.save(responseStatus, responseBody);
  return new Response(JSON.stringify(responseBody), {
    status: responseStatus,
    headers: { "content-type": "application/json" },
  });
});
```

### 2.4 Client contract — `performHTTP` extension

```swift
extension SupabaseClient {
    /// Adds idempotency-key injection on top of M-I retry + M-III refresh.
    /// When `idempotent: true`, a fresh UUIDv4 is generated ONCE before the
    /// retry loop and the `Idempotency-Key` header is injected into the
    /// request copy used by every attempt — guarantees server-side dedup
    /// across all retries of a single logical call.
    internal func performHTTP(
        _ request: URLRequest,
        retryable: Bool,
        refreshable: Bool = false,
        idempotent: Bool = false,   // M-II addition
        label: String
    ) async throws -> (Data, HTTPURLResponse)
}
```

**Implementation sketch (added to M-I + M-III loop):**

```swift
internal func performHTTP(...) async throws -> (Data, HTTPURLResponse) {
    var currentRequest = request
    if idempotent {
        let key = UUID().uuidString.lowercased()
        currentRequest.setValue(key, forHTTPHeaderField: "Idempotency-Key")
    }
    // ... existing M-I retry loop using `currentRequest` ...
}
```

The header survives M-I retries (loop reuses `currentRequest`) and M-III refresh (refresh swaps `Authorization` header but leaves all others — including `Idempotency-Key` — intact).

### 2.5 Callsite tagging — exhaustive table

| # | Callsite | File | Verb | Endpoint | M-I `retryable` | M-III `refreshable` | M-II `idempotent` | Server change? |
|---|---|---|---|---|---|---|---|---|
| 1 | `performSignInAnonymously` | `SupabaseClient.swift` | POST | `/auth/v1/signup` | false | false | false | no (third-party) |
| 2 | `performTokenRefresh` | `SupabaseClient.swift` | POST | `/auth/v1/token` | false | false | false | no (third-party) |
| 3 | `performRegisterPubkey` | `SupabaseClient.swift` | POST | `/functions/v1/register_pubkey` | **true** | false | **true** | add middleware |
| 4 | `postInvite` | `SupabaseClient.swift` | POST | `/v1/invite/*` (legacy) | **true** | true | **true** | legacy CF Worker path; defer — leave `idempotent: false` v1, flip in M-II.b follow-up |
| 5 | `resolveInvite` | `SupabaseClient.swift` | POST | `/functions/v1/invite_resolve` | **true** | false | **true** | add middleware |
| 6 | `probeInvite` | `SupabaseClient.swift` | POST | `/functions/v1/invite_resolve` (probe variant) | **true** | false | **true** | same Edge fn, probe uses different body |
| 7 | `insertWorkspaceMember` | `SupabaseClient+Workspaces.swift` (relocated) | POST | **NEW** `/functions/v1/insert_workspace_member` | **true** | true | **true** | new Edge fn |
| 8 | `invokeCreateJoinRequest` | `+JoinRequests.swift` | POST | `/functions/v1/create_join_request` | **true** | true | **true** | add middleware |
| 9 | `invokeCancelJoinRequest` | `+JoinRequests.swift` | POST | `/functions/v1/cancel_join_request` | **true** | true | **true** | add middleware |
| 10 | `invokeApproveJoinRequest` | `+JoinRequests.swift` | POST | `/functions/v1/approve_join_request` | **true** | true | **true** | add middleware |
| 11 | `invokeDeclineJoinRequest` | `+JoinRequests.swift` | POST | `/functions/v1/decline_join_request` | **true** | true | **true** | add middleware |
| 12 | `invokeDeleteInviteToken` | `+JoinRequests.swift` | POST | `/functions/v1/delete_invite_token` | **true** | true | **true** | add middleware |
| 13 | `insertInviteToken` | `+InviteTokens.swift` | POST | **NEW** `/functions/v1/insert_invite_token` | **true** | true | **true** | new Edge fn |
| 14 | `sendDirectMessage` | `+DirectMessages.swift` | POST | `/rest/v1/direct_messages` | **true** | true | **true** | PostgREST → keeping as PostgREST is incorrect (no header check) → wrap in **NEW** `/functions/v1/send_direct_message` |
| 15 | `triggerAPNsPush` | `+DirectMessages.swift` | POST | `/functions/v1/apns_push` | **true** | true | **true** | add middleware |
| 16 | `registerAPNsToken` | `+DirectMessages.swift` | POST (UPSERT) | `/rest/v1/apns_tokens` | **true** | true | **false** | no — UPSERT idempotent |
| 17 | `triggerSlackPost` | `+CrossPost.swift` | POST | `/functions/v1/slack_post` | **true** | true | **true** | add middleware |
| 18 | `triggerLinearCreate` | `+CrossPost.swift` | POST | `/functions/v1/linear_create_issue` | **true** | true | **true** | add middleware; delete legacy body field |
| 19 | `upsertNotificationPref` | `+NotificationPrefs.swift` | POST (UPSERT) | `/rest/v1/notification_prefs` | **true** | true | **false** | no — UPSERT idempotent |
| 20 | `sendTeamEvent` | `+TeamEvents.swift` | POST | **NEW** `/functions/v1/send_team_event` | **true** | true | **true** | new Edge fn |
| 21 | `insertWorkspace` | `+Workspaces.swift` | POST | **NEW** `/functions/v1/insert_workspace` | **true** | true | **true** | new Edge fn |
| 22 | `submitToWaitlist` | `+Waitlist.swift` | POST | **NEW** `/functions/v1/submit_waitlist` | **true** | true | **true** | new Edge fn (anon) |

**Summary:**
- **17 client POST callsites carry `idempotent: true`** (16 distinct Edge Functions — `resolveInvite` and `probeInvite` both target `invite_resolve`).
- **16 Edge Functions wired with middleware**:
  - **10 existing modified**: `create/cancel/approve/decline_join_request`, `delete_invite_token`, `invite_resolve`, `register_pubkey`, `apns_push`, `slack_post`, `linear_create_issue`.
  - **6 new**: `insert_workspace`, `insert_invite_token`, `insert_workspace_member`, `send_team_event`, `send_direct_message`, `submit_waitlist`.
- **2 UPSERT POSTs**: flip `retryable: true` only (`registerAPNsToken`, `upsertNotificationPref`).
- **2 Supabase Auth POSTs**: unchanged.
- **1 legacy `postInvite`**: defer (CF Worker `/v1/invite/*` — different infra). Leave `idempotent: false` in this phase; address in M-II.b follow-up if/when CF Worker is wired through.

### 2.6 Body shape — request canonicalization for hashing

To make `request_hash` deterministic across attempts, the **hash input is the raw bytes the client sent** — not a re-serialized canonical form. Reasoning:
- Client builds the body once (Swift `JSONEncoder` is deterministic for the same struct + key strategy) and sends those exact bytes on every retry.
- M-I retry loop sends the same `URLRequest.httpBody` (Data is immutable).
- M-III refresh leaves `httpBody` untouched (only mutates `Authorization` header).
- Server hashes the bytes it receives — `await req.arrayBuffer()` → SHA-256 → compare with stored `request_hash`.

**Risk:** if a client retry serializes a struct with a non-deterministic field order (e.g., dict literal in Swift), the hash differs → 422. Mitigation: all Swift POST bodies use `Codable` structs (compiler-generated keyed encoder, stable order). Phase B commit 7 (PostgREST → Edge rewrites) explicitly audits each rewritten callsite to confirm `Codable` struct usage; the 11 existing Edge POST callsites already use named structs (verified for the 5 grep-inspected during design + by precedent — M-I migration touched all and would have surfaced any dict-literal bodies).

---

## 3. Server design details

### 3.1 RLS + safety

- `idempotency_log` RLS enabled, no policies → all access via service_role only.
- Service_role JWT is server-side env var, never reaches clients.
- Edge Functions running under service_role are the only readers/writers.
- `owner_pubkey` is metadata, not a security boundary — replay decision is **key + hash** alone. A leaked key by itself is harmless (need exact body match to replay). Future hardening (M-II.b): bind replay to `owner_pubkey` — reject hit if requesting JWT pubkey differs from stored. **Out of M-II scope** — keep first cut simple.

### 3.2 Save policy

| Handler outcome | Save to `idempotency_log`? | Reasoning |
|---|---|---|
| 2xx success | yes | Replay returns identical success — happy path. |
| 4xx deterministic (e.g. `invite_expired`, `invite_not_found`) | yes | Same request → same answer always. Replay avoids re-running RPC for known failure. |
| 4xx auth (401, 403) | **no** | Auth state may change between attempts (M-III refresh, RLS policy edit). Let retry re-evaluate. |
| 5xx | **no** | Transient — let M-I retry hit a fresh handler. |
| Network-level (handler crashes pre-response) | **no** (never reached `save`) | Same as 5xx — retry safe. |

In TypeScript:
```ts
await idem.save(responseStatus, responseBody);  // middleware filters: skip if status >= 500 OR status == 401 OR status == 403
```

### 3.3 New Edge Functions (6) — shape

Each follows the same pattern as existing functions:
1. CORS / method check.
2. Auth (`getUser` + `extractPubkey` for authed flows; skip for waitlist).
3. Read body bytes via `req.arrayBuffer()`.
4. `checkIdempotency` → replay or miss.
5. On miss: validate body, perform INSERT (via service_role `supabase.from(table).insert(...)`), build response.
6. Call `idem.save(status, body)` then return.

**`insert_workspace`** (`{ name, workspace_id, created_at_ms }` body; returns the inserted row).
**`insert_invite_token`** (body: `{ workspace_id, code, expires_at_ms }`; returns full row).
**`insert_workspace_member`** (body: `{ workspace_id, member_pubkey, role, joined_at_ms }`; returns row).
**`send_team_event`** (body: `{ workspace_id, kind, payload_ciphertext, recipient_pubkey?, ... }`; returns `{ event_id, created_at_ms }`).
**`send_direct_message`** (body: `{ recipient_pubkey, ciphertext, ... }`; returns `{ message_id, created_at_ms }`).
**`submit_waitlist`** (body: `{ email, source?, ... }`; **anon** flow — no auth header required; returns `{ ok: true }`).

Each function = ~50 LOC including the idempotency wiring. Net ~300 LOC TS for the 6 new functions.

### 3.4 Cron prune

Reuses existing `pg_cron` extension (already enabled per `20260513121000_retention_purge_cron.sql`).
- Schedule: `17 3 * * *` (03:17 UTC daily — chosen off-peak to avoid contention with retention purge at 03:00).
- Function: `prune_idempotency_log()` returns count of deleted rows for diagnostics (visible in `cron.job_run_details`).
- Failure mode: if cron skips a night, table grows by ~1 day of POSTs. Bounded — fix on next run.

---

## 4. Client design details

### 4.1 UUID generation point

Inside `performHTTP`, **before** the retry loop:

```swift
var currentRequest = request
if idempotent {
    currentRequest.setValue(
        UUID().uuidString.lowercased(),
        forHTTPHeaderField: "Idempotency-Key"
    )
}
```

- One UUID per `performHTTP` invocation → all retries of a single logical call share the key.
- Distinct user-initiated calls (caller invokes the public method again after the original returns) → distinct UUIDs → no dedup. Correct semantic: user explicitly retried, treat as new operation.
- UUID().uuidString in Swift uses CryptoKit-strong randomness → no collisions in practice.

### 4.2 PostgREST → Edge migration

Five callsites move from `/rest/v1/<table>` (PostgREST INSERT) to `/functions/v1/<fn_name>` (Edge Function).

For each, the client-side changes:
1. **URL**: `SupabaseEndpoint.<table>` → `SupabaseEndpoint.<fn_name>` (new constant).
2. **Body shape**: same fields, but POST body becomes the function's input object (e.g., `{ name, workspace_id, created_at_ms }` instead of a PostgREST INSERT row shape with `Prefer: return=representation`).
3. **Headers**: remove `Prefer: return=representation`. Edge functions return the row by default.
4. **Response decode**: same struct (Edge fn returns the same JSON shape PostgREST did, for compat).
5. **Auth**: same — Authorization Bearer from session.

These rewrites are **mechanical** (per-callsite ~10 lines changed). Total `+200 / −150` LOC across 5 files.

### 4.3 Tests — what each scenario verifies

`SupabaseClientIdempotencyTests.swift` (~15 tests via MockURLProtocol):

1. `idempotent_true_injectsIdempotencyKeyHeader_validUUIDv4Format`.
2. `idempotent_false_doesNotInjectHeader`.
3. `idempotent_retryOn502_secondAttemptCarriesSameKey` — script `[502, 200]`. Verify both requests captured by mock have identical `Idempotency-Key` header value.
4. `idempotent_retryOn503_thirdAttemptCarriesSameKey` — `[503, 503, 200]`. Verify 3 calls, all same key.
5. `idempotent_replay200_returnsServerBody` — single call, mock returns 200 + body `{request_id: "abc"}`. Verify decoded result matches.
6. `idempotent_mismatch422_surfacesAsServerError` — mock returns 422 `{error: "idempotency_key_mismatch"}`. Verify `SupabaseError.serverError(422)` thrown.
7. `idempotent_missingKey400_surfacesAsTransport` — mock returns 400 `{error: "missing_idempotency_key"}` (synthetic — client SHOULD always send key when idempotent=true; test verifies surface).
8. `idempotent_refreshableAfter401_keyPreservedAcrossRefresh` — `[401, 200]` script + token refresh in between. Verify the second attempt carries (a) the same idempotency key, (b) the rotated Bearer token.
9. `idempotent_distinctCallsGenerateDistinctKeys` — invoke same public method twice; assert mock saw 2 different UUIDs.
10. `nonIdempotentPostReuse_doesNotCarryKey` — UPSERT path (`registerAPNsToken`); verify no header injected.
11. `idempotent_retryOn429WithRetryAfter_keyPreserved`.
12. `idempotent_networkErrorRetry_keyPreserved` — `URLError(.networkConnectionLost)` + 200.
13. `legacyAuthPost_signInAnonymously_noKeyInjected`.
14. `legacyAuthPost_performTokenRefresh_noKeyInjected`.
15. `linearCreateIssue_doesNotIncludeLegacyBodyField` — assert request body JSON has no `idempotency_key` property (we deleted it; M-II uses header).

**Server-side tests** (10 Deno unit tests across `_shared/idempotency.test.ts` + per-fn `test.ts`):

1. `checkIdempotency_missingHeader_returns400`.
2. `checkIdempotency_invalidUUIDFormat_returns400`.
3. `checkIdempotency_firstCall_returnsReplayFalse`.
4. `checkIdempotency_secondCallSameKeySameBody_returnsReplayHit`.
5. `checkIdempotency_secondCallSameKeyDifferentBody_returns422`.
6. `checkIdempotency_expiredKey_treatedAsMiss`.
7. `checkIdempotency_save_persistsResponseAndHash`.
8. `checkIdempotency_save_skipsOn5xxStatus`.
9. `checkIdempotency_save_skipsOn401_403`.
10. `checkIdempotency_anonOwnerPubkey_storedAsNull`.

Plus per-new-Edge-fn smoke (1 happy-path + 1 dup-replay) — 12 tests total across the 6 new functions.

---

## 5. Error handling matrix (summary)

| Condition | Server response | Server `save`? | Client `performHTTP` behavior | Surfaces to caller as |
|---|---|---|---|---|
| Idempotency-Key missing/invalid format | 400 `missing_idempotency_key` | n/a | M-I `.giveUp` (4xx) | `SupabaseError.serverError(400)` |
| Replay hit (same key + same hash) | 200/201 + cached body | n/a (already saved) | M-I `.giveUp` (2xx) | success — caller decodes body |
| Replay hit (4xx cached, e.g. `invite_expired`) | 410 + cached error body | n/a | M-I `.giveUp` (4xx) | `SupabaseError.<deterministic case>` |
| Mismatch (same key + different hash) | 422 `idempotency_key_mismatch` | no | M-I `.giveUp` (4xx) | `SupabaseError.serverError(422)` — client bug, treat as fatal |
| Miss → handler 2xx | 2xx + body | yes | M-I `.giveUp` (2xx) | success |
| Miss → handler 4xx (deterministic) | 4xx + body | yes (status ∉ {401,403}) | M-I `.giveUp` (4xx) | `SupabaseError.<case>` |
| Miss → handler 401 | 401 | **no** | M-III refresh → retry once with new JWT | success on retry OR `.unauthorized` if persistent |
| Miss → handler 5xx | 5xx | **no** | M-I `.retry` | success on retry OR `.serverError` after exhaustion |
| Miss → handler 429 + Retry-After | 429 + header | **no** | M-I `.retry(after: header)` | success or `.rateLimited` |
| Network error (TCP RST, DNS, timeout) | n/a (no response) | n/a | M-I `.retry` | success on retry OR `.transport` |

---

## 6. Acceptance criteria

1. **Build green**: `xcodebuild` 5/5 schemes (`Leaf`, `LeafAgent`, `LeafMCPServer`, `LeafCore`, `LeafCorePrivate`).
2. **Swift SPM**: `swift test --package-path Packages/LeafCore` — baseline (~2185 from M-I + M-III delta) preserved + 15 net new idempotency tests. Total ~2200.
3. **Swift idempotency tests**: `swift test --filter SupabaseClientIdempotencyTests` — all 15 pass.
4. **Deno unit tests**: `cd leaf-relay && deno test supabase/functions/_shared/idempotency.test.ts` — all 10 pass. Per-new-fn `test.ts` — all 12 pass.
5. **pgTAP**: `supabase test db` — baseline + 2 new files (`290_idempotency_log.test.sql` + `300_idempotency_cron.test.sql`). All scenarios green.
6. **Callsite audit** (mechanical grep against §2.5 table):
   - All 17 idempotent-true POST callsites pass `idempotent: true`.
   - Both UPSERT POSTs pass `retryable: true, idempotent: false`.
   - 2 Auth POSTs unchanged (no `idempotent` arg, defaults to `false`).
   - 1 legacy `postInvite` unchanged in this phase (`idempotent: false`).
   - `linear_create_issue` request body in Swift contains no `idempotency_key` field (legacy body field removed).
7. **Manual smoke** (best-effort against live Supabase if available):
   - WiFi blink during a `create_join_request` POST: server logs show 2 incoming requests with same Idempotency-Key; `join_requests` table has exactly 1 row; client UI shows success (not duplicate request error).
   - Re-send same `create_join_request` body twice with the same key (curl): second response replays first body.
   - Same key + altered body: 422.
8. **`/pre-push-leaf`** — clean. Idempotency-Key is a generic HTTP pattern, no moat.

---

## 7. Scope / non-goals

**In M-II:**
- M028 migration + nightly prune cron.
- `_shared/idempotency.ts` middleware.
- 10 existing Edge Functions wired with middleware.
- 6 new Edge Functions wrapping former PostgREST POSTs.
- Client `performHTTP` `idempotent` flag + 15 callsite tags + 2 UPSERT retryable flips + 5 PostgREST → Edge rewrites + 1 callsite relocation (`insertWorkspaceMember`).
- Delete legacy `idempotency_key` body field in `linear_create_issue` (both server + client).
- Tests: 15 Swift + 10 Deno + 12 per-fn + 6 pgTAP.

**Out of M-II (deferred to follow-ups):**
- M-II.b — bind replay to `owner_pubkey` (defence-in-depth against leaked key + crafted body match).
- M-II.c — `postInvite` legacy CF Worker `/v1/invite/*` path. Different infra; will need a CF Worker–side idempotency layer or migration off CF Worker.
- Telemetry on dedup hit-rate / 422 mismatch frequency. (Out: no metrics substrate in `leaf-relay` today.)
- Response cache replay for non-JSON content types. (Out: all 15 functions return JSON.)
- HTTP-date format for `Retry-After`. (Already excluded per M-I.)
- Per-function rate limits keyed on `owner_pubkey`. (Different concern.)

**Won't do:**
- Change `SupabaseError` cases. Mismatch and missing-key surface as `.serverError(422)` / `.transport(reason:)`.
- Modify `MockURLProtocol`. Closure-handler is sufficient.
- Add Idempotency-Key to Supabase Auth endpoints. Third-party.
- Add Idempotency-Key to GETs / PATCHes. Already idempotent.

---

## 8. Open questions

None blocking. Future considerations (not in M-II scope):

- **Q1.** Should `owner_pubkey` become part of the PK to scope replay per user? Adds defence-in-depth; trades simpler lookup. Pick up in M-II.b.
- **Q2.** Should we expose `idempotency_log` row count + 24h hit-rate via a debug endpoint or admin RPC? Useful for tuning TTL post-launch. Defer to telemetry track.
- **Q3.** Should we treat `request_hash` mismatch as **always 422** or sometimes as **server-side bug surfacing** (e.g., a known-bug allowlist)? Keep strict 422 for now; loosen only if a real callsite hits it.
- **Q4.** Should `submit_waitlist` require anon JWT (signInAnonymously first) or be truly unauthenticated? Currently PostgREST waitlist accepts anon — Edge fn should match. Verified: anon flow OK, no auth header check.
- **Q5.** Should `idempotency_log` survive across Supabase project restore / branch promotion? Yes — it's a regular table, restores like any other. No special handling needed.

---

## 9. Sequencing + commit decomposition

**Phase 0 — Pre-M-II (close dirty WIP on `leaf-relay`):**
1. **leaf-relay**: `feat(invite-redesign): atomic consume_invite + one-pending-per-pubkey constraint` — commits `20260602120000_invite_consume_at_create.sql` + `20260603120000_invite_one_pending_per_pubkey.sql` migrations, the modified `create_join_request/{index,test}.ts` + `approve_join_request/{index,test}.ts`, pgTAP `270` + `280`, deno.lock. Verify locally via `supabase test db`. Push.

**Phase A — Server (leaf-relay):**
2. `feat(supabase): M028 idempotency_log table + nightly prune cron`
   - 2 migrations (`20260604120000` + `20260604120100`).
   - pgTAP `290_idempotency_log.test.sql` + `300_idempotency_cron.test.sql`.
3. `feat(supabase): _shared/idempotency middleware + Deno unit tests`
   - `_shared/idempotency.ts` + `_shared/idempotency.test.ts` (10 tests).
4. `feat(supabase): apply idempotency middleware to 10 existing Edge Functions`
   - Wire `checkIdempotency` / `idem.save` into `create/cancel/approve/decline_join_request`, `delete_invite_token`, `invite_resolve`, `register_pubkey`, `apns_push`, `slack_post`, `linear_create_issue`.
   - Delete legacy `idempotency_key` body field from `linear_create_issue`.
   - Update each function's `test.ts` to include 1 happy-path + 1 dup-replay scenario (~10 added tests across the 10 functions).
5. `feat(supabase): 6 new Edge Functions wrapping PostgREST INSERTs`
   - `insert_workspace`, `insert_invite_token`, `insert_workspace_member`, `send_team_event`, `send_direct_message`, `submit_waitlist` — each with `index.ts` + `test.ts` (2 tests each = 12 tests).

**Phase B — Client (leaf):**
6. `feat(supabase): performHTTP idempotent flag + UUID header injection`
   - `SupabaseClient+Retry.swift` extension.
   - 15 unit tests in `SupabaseClientIdempotencyTests.swift` (pure behavior; no callsite churn).
7. `refactor(supabase): replace 5 PostgREST INSERT POSTs with Edge Function calls`
   - `+Workspaces.swift` (insertWorkspace, insertWorkspaceMember relocated), `+InviteTokens.swift` (insertInviteToken), `+TeamEvents.swift` (sendTeamEvent), `+Waitlist.swift` (submitToWaitlist), `+DirectMessages.swift` (sendDirectMessage).
   - `SupabaseEndpoint.swift` add 6 new constants, remove 5 PostgREST endpoints.
   - Update existing tests for each rewritten callsite (URL / body shape assertions).
8. `refactor(supabase): flip retryable+idempotent on 15 Edge POSTs + 2 UPSERTs retryable-only`
   - Per §2.5 table.

**Phase C — Verification:**
9. `superpowers:code-reviewer` subagent → independent review against this spec + commits.
10. `superpowers:receiving-code-review` — address each finding.
11. `superpowers:verification-before-completion` — all checks (§6) actually run.

**VPS deploy** (post-merge, after Track 5 + Invite Redesign collective merge):
- `cd leaf-relay && supabase db push` (M028 migrations: idempotency_log + cron + Phase 0 atomic-consume + one-pending-per-pubkey).
- `supabase functions deploy <fn>` × 16 (10 existing modified + 6 new) on production `jwxnhwyqjzjmjnmwpwyq`.
- Verify cron entry: `select * from cron.job where jobname = 'prune-idempotency-log';`.

Total commits: 1 (Phase 0) + 4 (Phase A) + 3 (Phase B) = **8 commits**. Effort estimate: 1 focused session.

---

## 10. Verification checklist

- [ ] **Phase 0 closed**: dirty WIP committed + pushed to `feature/invite-redesign` (leaf-relay).
- [ ] Build green: `xcodebuild` 5/5 schemes.
- [ ] Swift SPM: baseline preserved + 15 new idempotency tests pass.
- [ ] Deno: 10 middleware unit tests + 22 per-function tests (12 for new + 10 added to existing) green.
- [ ] pgTAP: 290 + 300 + all baseline files green.
- [ ] Mechanical callsite audit (§2.5) — grep verifies all 22 POSTs match the table.
- [ ] `linear_create_issue` legacy body field deleted in both server (`index.ts`) and client (`+CrossPost.swift`).
- [ ] Manual smoke (best-effort against live Supabase): WiFi blink during create_join_request → exactly 1 join_requests row, client UI clean.
- [ ] `superpowers:code-reviewer` subagent independent review passed.
- [ ] `/pre-push-leaf` clean.
- [ ] VPS deploy planned + scripted (post-merge).
