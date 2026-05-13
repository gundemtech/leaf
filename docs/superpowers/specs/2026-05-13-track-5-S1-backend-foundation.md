# Track 5 / S1 — Backend Foundation

**Sub-phase of:** Track 5 — Collaboration Redesign ([contract](2026-05-13-track-5-collaboration-contract.md))
**Status:** Draft (2026-05-13)
**Branch (this repo):** `feature/track-5-S1-backend-foundation`
**Parallel branch (leaf-relay):** `feature/track-5-S1-supabase-foundation`
**Owner-side:** Local Claude (Mac) writes code; VPS Claude deploys after merge (per Track 5 contract §17)
**Workflow:** 8 stages per `conventions.md` "Одна phase = одна сессия"

---

## 1. Purpose

S1 ships the **Supabase backend foundation** for Track 5: schema, RLS policies, Edge Function skeletons, cron job skeletons, and an APNs gateway stub — without any real API integrations (those land in S4 / S6). After S1 merges + VPS deploy:

- Subsequent Track 5 sub-phases (S2 multi-workspace substrate, S3 magic-link invite, S4 direct messages, S5 auto-share, S6 cross-post) have a **stable backend contract** to wire against
- Mac client code (Swift) can begin authenticating against Supabase Auth, registering pubkey, and issuing JWT-bearing reads/writes against tables protected by RLS
- The four Edge Functions exist as deploy targets, returning `{ok: true, stub: true}` until their real bodies arrive

S1 is **foundation only** — no end-user feature ships from S1 alone.

---

## 2. Goal — fitness function

S1 is **done** when locally (on author's Mac) all of the following hold:

| # | Check | How to verify |
|---|---|---|
| **G1** | All 12 migrations apply clean | `supabase db reset` succeeds, no errors |
| **G2** | Local stack is reset-stable | Repeated `supabase db reset` succeeds (db drops + replays cleanly each invocation) |
| **G3** | RLS allow path works | pgTAP: member can SELECT own workspace's `team_events` |
| **G4** | RLS deny path works | pgTAP: non-member SELECT returns 0 rows for foreign workspace |
| **G5** | Direct message RLS | pgTAP: sender/recipient SELECT works; third party SELECT returns 0 |
| **G6** | INSERT RLS check | pgTAP: INSERT into `team_events` rejected when `auth.jwt() ->> 'pubkey'` not in workspace_members |
| **G7** | Custom claim works | pgTAP: Auth Hook function callable + emits `pubkey` claim when invoked with mocked auth_id |
| **G8** | Workspace name uniqueness | pgTAP: INSERT duplicate `(created_by_pubkey, name)` rejected; different admin same name OK |
| **G9** | 4 Edge Functions serve | `supabase functions serve` + `curl` each returns `{"ok":true,"stub":true}` |
| **G10** | Cron schedules registered | `SELECT jobname FROM cron.job` shows `retention_purge` + `task_reminders` |

Track 5 acceptance gate (UC-T5-1 through UC-T5-7) is **not** an S1 acceptance criterion — S1 is foundation only.

---

## 3. Out of S1 scope

Explicitly **not** in this sub-phase:

- Swift on-device code (`Packages/LeafCore/Sources/LeafCore/Network/SupabaseClient.swift` or similar) — comes in S2 or later
- SQLCipher migrations M019+ (on-device schema for multi-workspace) — S2
- Real APNs delivery (uses real `.p8` key + `node-apn` or `web-push-libs/apn`) — S4
- Real Slack `chat.postMessage` API call — S6
- Real Linear `issueCreate` GraphQL mutation — S6
- Magic-link `invite_resolve` real cryptographic verification — S3 wires it; S1 stub returns `{ok: true}`
- `register_pubkey` Edge Function challenge-response — S3
- VPS deployment (Supabase project creation, `supabase link`, `supabase db push`, secrets configuration) — VPS Claude handoff after S1 merge
- CI workflow (GitHub Actions auto-deploy on push to leaf-relay main) — VPS Claude
- Supabase Realtime subscription wiring — S4 (when first consumer appears)

---

## 4. Architecture

```
~/Desktop/Leaf/leaf-relay/             (private repo — gundemtech/leaf-relay)
├── src/                                Cloudflare Workers (untouched — sunset trajectory per Track 5 §3)
├── tests/                              Vitest (untouched)
├── supabase/                           NEW — S1 scope
│   ├── config.toml                     supabase project config (checked in)
│   ├── migrations/                     12 SQL files (timestamp-prefixed)
│   ├── functions/
│   │   ├── _shared/                    helper module (cors header constant)
│   │   ├── apns_push/index.ts          stub Edge Function
│   │   ├── invite_resolve/index.ts     stub
│   │   ├── slack_post/index.ts         stub
│   │   └── linear_create_issue/index.ts  stub
│   ├── tests/database/                 pgTAP *.sql files
│   └── seed.sql                        empty (placeholder)
├── package.json                        existing — extend `scripts` with supabase commands; no new runtime deps
└── CLAUDE.md                           update — add `supabase/` subsection
```

Two test runners coexist in repo:
- **Vitest** (existing) — `src/` Cloudflare Workers tests
- **pgTAP** (new) — `supabase/tests/database/` RLS tests via `supabase test db`

No Deno test for Edge Functions in S1 — handlers are stubs, real tests arrive when real bodies do (S4 / S6).

---

## 5. Schema — 12 migrations

All migrations follow Supabase convention: `<timestamp>_<snake_case_name>.sql`. Timestamps are sequential within the same day, spaced by 100 seconds for readability.

### 5.1 Migration list

| # | File | Purpose |
|---|---|---|
| 1 | `20260513120000_workspaces.sql` | `workspaces(id, name, created_by_pubkey, created_at)` + UNIQUE(created_by_pubkey, name) |
| 2 | `20260513120100_pubkey_registry.sql` | `pubkey_registry(auth_id, pubkey UNIQUE, registered_at)` — **amendment to Track 5 contract §5.1** (auth bridge) |
| 3 | `20260513120200_workspace_members.sql` | `workspace_members(workspace_id, pubkey, display_name, joined_at, removed_at)` |
| 4 | `20260513120300_workspace_keys.sql` | `workspace_keys(workspace_id, key_id, ecdh_wrap, recipient_pubkey, posted_at, ack_at)` |
| 5 | `20260513120400_team_events.sql` | `team_events(workspace_id, event_id, sender_pubkey, encrypted_payload, kind, created_at, expires_at)` |
| 6 | `20260513120500_direct_messages.sql` | `direct_messages(workspace_id, message_id, sender_pubkey, recipient_pubkey, kind, encrypted_payload, cross_post, created_at, read_at, done_at, done_by_pubkey, reply_to)` |
| 7 | `20260513120600_invites.sql` | `invites(token PK, workspace_id, admin_pubkey, encrypted_teamkey, expires_at, require_otp, otp_hash, claimed_at, claimed_by_pubkey)` |
| 8 | `20260513120700_apns_tokens.sql` | `apns_tokens(pubkey, apns_token, device_id, updated_at)` |
| 9 | `20260513120800_cross_post_log.sql` | `cross_post_log(message_id FK, channel, external_ref, posted_at, error_text)` |
| 10 | `20260513120900_rls_policies.sql` | All RLS policies in one file (9 tables × policies) |
| 11 | `20260513121000_retention_purge_cron.sql` | `pg_cron` extension + daily 03:00 UTC schedule deleting expired `team_events` |
| 12 | `20260513121100_task_reminders_cron.sql` | `pg_cron` daily 09:00 UTC schedule (body is `SELECT 1` stub; real reminder logic in S4 with APNs) |

### 5.2 Amendment to Track 5 contract §5.1

Per Track 5 contract §18 (living document), S1 amends §5.1 to add one table not in the original schema:

> **Amendment 2026-05-13 (S1 spec):** Added `pubkey_registry` table — `(auth_id uuid PK REFERENCES auth.users(id) ON DELETE CASCADE, pubkey text UNIQUE NOT NULL, registered_at timestamptz NOT NULL DEFAULT now())`. Required by Supabase Auth + custom claim pattern (S1 §6) — bridges Supabase's `auth.users.id` UUID to Leaf's X25519 pubkey identity. Used by `custom_access_token_hook` Auth Hook to inject `pubkey` claim into JWT.

### 5.3 Column types

- All `pubkey` columns — `text` (hex-encoded X25519 public key, 64 chars)
- All `encrypted_payload` / `encrypted_teamkey` / `ecdh_wrap` / `otp_hash` — `bytea`
- All foreign keys — `uuid` (Supabase / Postgres default)
- All timestamps — `timestamptz NOT NULL DEFAULT now()` unless nullable per Track 5 contract §5.1
- `cross_post` on `direct_messages` — `jsonb` (Track 5 §5.1)
- `kind` columns — `text` (Track 5 §5.1 leaves enum-vs-text open; S1 chooses `text` for easier amendments, with CHECK constraint only where domain is closed today):
  - `team_events.kind text NOT NULL` — no CHECK (closed set defined in S5 when sources are wired)
  - `direct_messages.kind text NOT NULL CHECK (kind IN ('handoff', 'task', 'ping'))` — closed per Track 5 §8.1
  - `cross_post_log.channel text NOT NULL CHECK (channel IN ('slack', 'linear'))` — closed per Track 5 §9

### 5.4 Indexes

Each table gets minimum:
- Primary key index (automatic)
- Index on every foreign key column (Postgres does not auto-index FKs)
- Index on `workspace_id` for tenant-scoped queries
- Index on `expires_at` (partial WHERE NOT NULL) for `team_events` retention cron

No premature indexes for query patterns S1 doesn't yet have.

---

## 6. RLS policy approach

Single migration `20260513120900_rls_policies.sql` enables RLS + creates policies for all 9 application tables. **Pattern: broad `FOR ALL USING (...)` where same condition applies to all commands; explicit `FOR SELECT` / `FOR INSERT WITH CHECK` only when different conditions diverge between read and write.**

### 6.1 Pattern — workspace-scoped table

```sql
ALTER TABLE team_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY team_events_member_only ON team_events FOR ALL
  USING (
    workspace_id IN (
      SELECT workspace_id FROM workspace_members
      WHERE pubkey = (auth.jwt() ->> 'pubkey')
        AND removed_at IS NULL
    )
  )
  WITH CHECK (
    sender_pubkey = (auth.jwt() ->> 'pubkey')
    AND workspace_id IN (
      SELECT workspace_id FROM workspace_members
      WHERE pubkey = (auth.jwt() ->> 'pubkey')
        AND removed_at IS NULL
    )
  );
```

Note the WITH CHECK enforces sender attribution — caller cannot forge `sender_pubkey` of another user.

### 6.2 Pattern — sender/recipient scoped table

```sql
ALTER TABLE direct_messages ENABLE ROW LEVEL SECURITY;

CREATE POLICY direct_messages_party_only ON direct_messages FOR ALL
  USING (
    sender_pubkey    = (auth.jwt() ->> 'pubkey')
    OR recipient_pubkey = (auth.jwt() ->> 'pubkey')
  )
  WITH CHECK (
    sender_pubkey = (auth.jwt() ->> 'pubkey')
  );
```

### 6.3 Pattern — pubkey_registry (self-only)

```sql
ALTER TABLE pubkey_registry ENABLE ROW LEVEL SECURITY;

CREATE POLICY pubkey_registry_self_read ON pubkey_registry FOR SELECT
  USING (auth_id = auth.uid());

CREATE POLICY pubkey_registry_self_write ON pubkey_registry FOR INSERT
  WITH CHECK (auth_id = auth.uid());
```

(No UPDATE / DELETE — once registered, pubkey is permanent for that auth_id.)

### 6.4 Pattern — invites (anon-readable by token)

Invites are special — the magic-link recipient may not be authenticated yet. The `invites.token` itself is the auth capability (matches existing Cloudflare relay pattern per §A discovery). Policy allows SELECT by `service_role` only (Edge Function does the lookup); direct PostgREST access disabled:

```sql
ALTER TABLE invites ENABLE ROW LEVEL SECURITY;
-- No public policy. Only service_role (Edge Function `invite_resolve`) reads.
```

### 6.5 Policy coverage summary

| Table | Policy pattern |
|---|---|
| `workspaces` | member can SELECT; only admin (creator) can UPDATE/DELETE |
| `workspace_members` | members of workspace can SELECT all peers; admin INSERT/DELETE |
| `workspace_keys` | recipient_pubkey-scoped SELECT; service_role INSERT (via key-rotation Edge Function path, S3+) |
| `team_events` | workspace member scoped (§6.1) |
| `direct_messages` | sender/recipient scoped (§6.2) |
| `invites` | service_role only (§6.4) |
| `apns_tokens` | self-scoped (`pubkey = auth.jwt() ->> 'pubkey'`) |
| `cross_post_log` | sender/recipient-scoped via `message_id → direct_messages` join (same visibility as the underlying DM) |
| `pubkey_registry` | self-scoped (§6.3) |

---

## 7. Auth integration

### 7.1 Flow

```
First app launch (Mac client, future S2+ work):
  supabase.auth.signInAnonymously()
    └─> creates row in auth.users (no email/password)
    └─> returns JWT (no pubkey claim yet)

Soon after — pubkey registration (S3 challenge-response):
  client POSTs to Edge Function register_pubkey:
    { auth_id, pubkey, signature_over(challenge) }
  Edge Function verifies signature, INSERTs into pubkey_registry
  Next JWT refresh: Auth Hook injects pubkey claim
```

### 7.2 S1 deliverables for auth

1. **`pubkey_registry` migration** (S1 §5.1 #2) — schema
2. **Auth Hook function in `20260513120900_rls_policies.sql`** — Postgres function `custom_access_token_hook(event jsonb) RETURNS jsonb` that reads `pubkey_registry` and emits modified JWT claims. Follows the canonical Supabase Custom Access Token Hook template — `SECURITY DEFINER` (function must bypass RLS to read bridge table), pinned `search_path`, and explicit grant/revoke so only the Auth subsystem can invoke it:

```sql
CREATE OR REPLACE FUNCTION public.custom_access_token_hook(event jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  claims jsonb;
  user_pubkey text;
BEGIN
  claims := event -> 'claims';
  SELECT pubkey INTO user_pubkey FROM pubkey_registry
    WHERE auth_id = (event ->> 'user_id')::uuid;
  IF user_pubkey IS NOT NULL THEN
    claims := jsonb_set(claims, '{pubkey}', to_jsonb(user_pubkey));
  END IF;
  RETURN jsonb_set(event, '{claims}', claims);
END;
$$;

GRANT EXECUTE ON FUNCTION public.custom_access_token_hook TO supabase_auth_admin;
REVOKE EXECUTE ON FUNCTION public.custom_access_token_hook FROM authenticated, anon, public;
```

Hook activation (binding `custom_access_token_hook` to Supabase Auth) is a **dashboard / config setting**, not migration SQL — VPS Claude responsibility at deploy time. Documented in handoff (S1 §13).

3. **NOT in S1:** `register_pubkey` Edge Function challenge-response logic — that's S3. S1 doesn't ship this stub at all (Track 5 contract §17 lists 4 Edge Functions for S1: apns_push / invite_resolve / slack_post / linear_create_issue; `register_pubkey` belongs to S3 per contract §12).

---

## 8. Edge Functions — 4 stubs

### 8.1 Shared utilities — `supabase/functions/_shared/`

Only one shared module — `cors.ts` — standard CORS header constant. Auth verification is done per-function via `@supabase/supabase-js` client (canonical Supabase Edge Function pattern; no custom JWT verifier needed):

```typescript
// supabase/functions/_shared/cors.ts
export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
```

### 8.2 Function skeletons

All 4 functions share the same shape — canonical Supabase Edge Function template (`Deno.serve` built-in, `jsr:` imports, supabase-js for auth):

```typescript
// supabase/functions/apns_push/index.ts
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return new Response(JSON.stringify({ error: "Missing Authorization header" }), {
      status: 401,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } } }
  );
  const { data: { user }, error } = await supabase.auth.getUser();
  if (error || !user) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), {
      status: 401,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  // TODO(S4): wire real APNs delivery via .p8 key + JWT-signed APNs request
  return new Response(
    JSON.stringify({ ok: true, stub: true, fn: "apns_push" }),
    { headers: { ...corsHeaders, "Content-Type": "application/json" } }
  );
});
```

Per-function `TODO` comment points at the sub-phase landing its real body:

| Function | Real-body sub-phase | TODO label |
|---|---|---|
| `apns_push` | S4 | `TODO(S4): wire real APNs delivery via .p8 key + JWT-signed APNs request` |
| `invite_resolve` | S3 | `TODO(S3): resolve invite token, return encrypted_teamkey + admin_pubkey` |
| `slack_post` | S6 | `TODO(S6): POST to api.slack.com/api/chat.postMessage with sender's OAuth token` |
| `linear_create_issue` | S6 | `TODO(S6): POST GraphQL issueCreate to api.linear.app` |

### 8.3 Dependency policy

No pinned Deno std import — modern Supabase Edge Functions use `Deno.serve` built-in (no http/server import needed). `jsr:@supabase/supabase-js@2` pinned to major version `2.x` (default Supabase recommendation). No other runtime deps in S1 — real bodies (APNs, Slack, Linear clients) get pulled in by their respective sub-phases.

---

## 9. Cron jobs — 2 skeletons

### 9.1 `retention_purge`

```sql
-- 20260513121000_retention_purge_cron.sql
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
  'retention_purge',
  '0 3 * * *',  -- daily 03:00 UTC
  $$DELETE FROM team_events WHERE expires_at IS NOT NULL AND expires_at < now()$$
);
```

Body is real (DELETE statement), not stubbed — it's safe to run immediately (no `team_events` rows exist yet, no-op). Real shipping starts when S5 begins inserting auto-shared events with `expires_at = now() + 30 days`.

### 9.2 `task_reminders`

```sql
-- 20260513121100_task_reminders_cron.sql
SELECT cron.schedule(
  'task_reminders',
  '0 9 * * *',  -- daily 09:00 UTC
  $$SELECT 1 /* TODO(S4): send APNs reminder for direct_messages where kind='task' AND done_at IS NULL AND created_at < now() - interval '24 hours' */$$
);
```

Body is stub (`SELECT 1`). Real query + APNs invocation in S4.

---

## 10. Test approach — pgTAP only

### 10.1 Rationale

S1 acceptance gate covers two security-critical areas: **RLS correctness** (G3-G8) and **migration cleanness** (G1-G2). Edge Functions are stubs (G9 is `curl` smoke, no test code needed). Single test harness — pgTAP — handles both:

- `supabase test db` is built-in Supabase CLI command
- pgTAP tests are SQL files (zero extra runtime deps)
- Runs against same Postgres instance as `supabase db reset`

Deferring Deno tests for Edge Functions to the sub-phase that ships their real bodies (S3/S4/S6) avoids YAGNI — testing a `return {ok:true}` handler adds no value.

### 10.2 Test files

```
supabase/tests/database/
├── 010_migrations_clean.test.sql        sanity check — required extensions exist (pg_cron, pgcrypto if needed)
├── 020_workspace_uniqueness.test.sql    G8 — UNIQUE(created_by_pubkey, name) constraint
├── 030_rls_team_events.test.sql         G3, G4, G6 — workspace-scoped RLS
├── 040_rls_direct_messages.test.sql     G5 — sender/recipient scope
├── 050_rls_apns_tokens.test.sql         self-scoped RLS
├── 060_rls_pubkey_registry.test.sql     self-scoped RLS
├── 070_rls_workspace_members.test.sql   member-list visibility
├── 080_rls_workspace_keys.test.sql      recipient_pubkey-scoped SELECT
├── 090_rls_cross_post_log.test.sql      workspace-scoped via join
├── 100_rls_invites_service_only.test.sql  anon SELECT denied
├── 110_auth_hook.test.sql               G7 — custom_access_token_hook injects pubkey
└── 120_cron_registered.test.sql         G10 — both cron jobs present in cron.job
```

### 10.3 Per-test pattern

Each pgTAP file follows the same shape:

```sql
BEGIN;
SELECT plan(N);  -- expected assertion count

-- Setup: insert test data
INSERT INTO workspaces (id, name, created_by_pubkey) VALUES (...);
INSERT INTO workspace_members (workspace_id, pubkey) VALUES (...);

-- Mock JWT: set local role and claim
SET LOCAL role = 'authenticated';
SET LOCAL "request.jwt.claims" = '{"pubkey": "<test-pubkey>", "sub": "<auth-id>"}';

-- Assertion
SELECT results_eq(
  $$SELECT count(*) FROM team_events WHERE workspace_id = '<test-uuid>'$$,
  $$VALUES (1::bigint)$$,
  'member can SELECT own workspace events'
);

-- Negative case: foreign pubkey
SET LOCAL "request.jwt.claims" = '{"pubkey": "<foreign-pubkey>"}';
SELECT results_eq(
  $$SELECT count(*) FROM team_events WHERE workspace_id = '<test-uuid>'$$,
  $$VALUES (0::bigint)$$,
  'non-member SELECT returns 0 rows (RLS deny)'
);

SELECT * FROM finish();
ROLLBACK;
```

`BEGIN`/`ROLLBACK` ensures tests are isolated; `SET LOCAL` confines claim mocks to the transaction.

---

## 11. OQ resolutions

| OQ (from Track 5 contract §16) | S1 resolution |
|---|---|
| **OQ-T5-5** Workspace name uniqueness — globally or per-admin? | **Per-admin**. Constraint: `UNIQUE(created_by_pubkey, name)` on `workspaces`. Reasoning: global uniqueness creates user-facing "name already taken by stranger" failures; per-admin matches typical multi-tenant SaaS patterns. |

Other Track 5 contract OQs are explicitly deferred to their owning sub-phase spec (S2 OQ-T5-2 / S3 OQ-T5-4 / S6 OQ-T5-3 / S8 OQ-T5-1, OQ-T5-6).

---

## 12. Local dev workflow

### 12.1 First-time setup (author's Mac)

```bash
# Install Supabase CLI (Homebrew, one-time)
brew install supabase/tap/supabase

# Ensure Docker Desktop running (Supabase local stack requires it)
docker info > /dev/null || echo "Start Docker Desktop"

# In leaf-relay repo
cd ~/Desktop/Leaf/leaf-relay
supabase init    # creates supabase/ scaffolding if missing
```

### 12.2 Daily dev loop

```bash
cd ~/Desktop/Leaf/leaf-relay
supabase start              # start local Postgres + Edge Functions runtime (Docker)

# After editing migrations:
supabase db reset           # apply all migrations from scratch

# Run RLS tests:
supabase test db            # runs pgTAP tests

# Test Edge Functions locally:
supabase functions serve apns_push    # in one terminal
curl -i -X POST http://127.0.0.1:54321/functions/v1/apns_push \
  -H "Authorization: Bearer <local-jwt>" \
  -H "Content-Type: application/json" -d '{}'

# Stop when done:
supabase stop
```

### 12.3 What gets checked in

- `supabase/config.toml` — `project_id` set to `"leaf-relay"` (local container-naming label; independent of cloud project ref, which VPS Claude sets via `supabase link --project-ref <ref>`, not by editing this file)
- `supabase/migrations/*.sql` — all 12 files
- `supabase/functions/**/*.ts` — function code + shared utils
- `supabase/tests/database/*.sql` — pgTAP suite
- `supabase/seed.sql` (empty)
- `package.json` — extended `scripts` section (e.g., `"supabase:test": "supabase test db"`)
- `CLAUDE.md` (leaf-relay) — updated structure section

### 12.4 What does NOT get checked in

- `.supabase/` (gitignored) — local Supabase CLI state, Docker volumes pointer
- Any `.env` containing service role key / JWT secret
- Any `.p8` APNs key (handled by VPS Claude at deploy)

---

## 13. VPS Claude handoff

After S1 merges into `gundemtech/leaf-relay` main, hand off to VPS session with this prompt:

> Deploy Track 5 S1 backend. Code on `gundemtech/leaf-relay` main, subfolder `supabase/`. Spec: `~/Desktop/Leaf/leaf/docs/superpowers/specs/2026-05-13-track-5-S1-backend-foundation.md`.
>
> Tasks:
> 1. Create new Supabase project (region: closest to author's location). Verify `pg_cron` extension is available — enabled on all current tiers but worth confirming via Supabase Dashboard → Database → Extensions. If unavailable for the project's Postgres version, fallback: drop migrations 11/12 and re-implement schedules via [Supabase Edge Function cron](https://supabase.com/docs/guides/functions/schedule-functions).
> 2. `cd ~/leaf-relay && supabase login && supabase link --project-ref <new-ref>`
> 3. `supabase db push` — apply all 12 migrations to remote
> 4. `supabase functions deploy apns_push invite_resolve slack_post linear_create_issue`
> 5. Configure secrets in Supabase dashboard:
>    - `SUPABASE_JWT_SECRET` — auto-populated; verify present
>    - APNs `.p8` key registry — placeholder for S4 deploy (skip if S4 not yet shipped)
>    - Slack/Linear OAuth credentials — placeholder for S6 (skip if S6 not yet shipped)
> 6. Activate Auth Hook: Supabase Dashboard → Authentication → Hooks → set `custom_access_token_hook` to `public.custom_access_token_hook` (PostgreSQL function in `20260513120900_rls_policies.sql`)
> 7. Add GitHub Action workflow `.github/workflows/supabase-deploy.yml`: on push to main, run `supabase db push` + `supabase functions deploy`
> 8. Smoke test: from local laptop, hit production Edge Function endpoints — expect 401 (no JWT) or `{ok: true, stub: true}` (with valid anon JWT)
>
> Do NOT ship S2 / S3 / S4 / S5 / S6 / S7 / S8 work — VPS is deploy/infra only. Mac sessions own feature implementation.

---

## 14. Acceptance criteria recap

S1 ships when all of G1-G10 from §2 pass on author's Mac. After merge to `feature/track-5-S1-supabase-foundation` in leaf-relay, VPS handoff (§13) executes; production smoke confirms remote endpoints respond.

S1 **does not gate** subsequent sub-phases — once VPS deploy is live, S2 / S3 / S4 / S5 / S6 / S7 / S8 can start in parallel sessions consuming the deployed backend.

---

## 15. Implementation plan

Detailed atomic-per-commit step-by-step plan lives in [`docs/superpowers/plans/2026-05-13-track-5-S1-backend-foundation.md`](../plans/2026-05-13-track-5-S1-backend-foundation.md), written next via `superpowers:writing-plans`. Plan covers:

- Sequential ordering of migrations / RLS / Edge Functions / tests
- Per-step acceptance check (per `superpowers:test-driven-development` discipline)
- Commit message templates per `conventions.md` Git rules
- Cross-repo coordination (leaf spec commits + leaf-relay code commits land in parallel branches; merge as collective Track 5 stack per Track 1/3/4 precedent)

---

## 16. Whitepaper sync

S1 alone does not warrant whitepaper sync. Track 5 contract §19 specifies whitepaper sync happens at end of S8 (full Track 5 ship). S1 ship: shared memory `current-state.md` updated only.

---

## 17. Living document

Per Track 5 contract §18, amendments expected during S1 implementation. Amendments inline annotated `> **Amendment YYYY-MM-DD (S1 impl):**`.

Already accepted amendments before implementation start:
- §5.2 — `pubkey_registry` table addition (auth bridge)

---

## 18. References

- Track 5 contract: [`2026-05-13-track-5-collaboration-contract.md`](2026-05-13-track-5-collaboration-contract.md)
- Phase 5 architecture contract: [`2026-05-04-phase-5-architecture-contract.md`](2026-05-04-phase-5-architecture-contract.md) — old Cloudflare-only design, repo split rule reference
- Track 1 sub-phase precedent: [`2026-05-09-track-1-D1-capture-extension.md`](2026-05-09-track-1-D1-capture-extension.md)
- Phase 5.1.A migrations precedent: [`2026-05-04-phase-5-1-A-migrations.md`](2026-05-04-phase-5-1-A-migrations.md)
- Supabase docs: [Auth Hooks](https://supabase.com/docs/guides/auth/auth-hooks) · [RLS](https://supabase.com/docs/guides/database/postgres/row-level-security) · [pg_cron](https://supabase.com/docs/guides/database/extensions/pg_cron) · [pgTAP testing](https://supabase.com/docs/guides/database/extensions/pgtap)
- Existing leaf-relay structure: `~/Desktop/Leaf/leaf-relay/{src,tests,wrangler.toml,package.json}`
