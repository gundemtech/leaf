# SupabaseClient 401 → ensureFreshSession → retry-once

**Status:** Draft (2026-05-22). Phase M-III from `optimization-tier-m.md`.
**Owner:** Local Claude (Mac).
**Branch:** `feature/invite-redesign` (on top of M-I, separate commit chain).
**Cross-reference:**
- `.claude/plans/optimization-tier-m.md` — audit punch list.
- M-I spec — `docs/superpowers/specs/2026-05-22-supabase-with-retry-design.md` (provides `performHTTP` shim that M-III extends).
- M-II — separate session, server-side `Idempotency-Key` dedup. Independent of M-III.

---

## 1. Goal — fitness function

The 401 auto-refresh wrapper is **done** when:

1. **JWT revoked / server-side rotation / clock skew** during an authenticated request → user does NOT see "auth error, restart required". The wrapper calls `ensureFreshSession()` and retries the request once with the new access token.
2. **Parallel 401s from concurrent ticks** (sidebar refresh + invite-token poll + DM fetch all firing in same window) share **one** `/auth/v1/token` POST via existing `inflightFreshSessionTask` coalescing — no refresh storm.
3. **Refresh-once budget is per-request and orthogonal to the M-I retry budget**: a request can be retried up to `maxAttempts` for 5xx/429 AND refreshed at most once for 401 within those attempts.
4. **Non-authenticated (anon) requests** (resolveInvite / probeInvite / signInAnonymously / tokenRefresh / submitToWaitlist) **never** trigger a refresh. They throw `.unauthorized` directly on 401, as today.
5. **Refresh itself failing** (network error during `/auth/v1/token`, or 401 from refresh endpoint) propagates the underlying error — no infinite refresh loops.
6. **No public API changes.** All `SupabaseClient` methods keep same signatures. Wrapper extends `performHTTP` and `<Verb>Transport` private helpers.
7. **No regressions** in 121 existing SupabaseClient* tests (incl. the pre-existing TeamEvents drift acknowledged in M-I; orthogonal).

---

## 2. Architecture

### 2.1 Files modified (no new source files)

- `Packages/LeafCore/Sources/LeafCore/Network/SupabaseClient+Retry.swift` — extend `performHTTP` signature with `refreshable: Bool = false` param + wire 401 path inside retry loop.
- 16 authenticated callsites across 9 extension files + `SupabaseClient.swift` core — pass `refreshable: true` (or wire it through private transport helpers).
- `Packages/LeafCore/Tests/LeafCoreTests/SupabaseClientRetryTests.swift` — append 5 integration tests (8 → 13 integration).

### 2.2 Public contract

```swift
extension SupabaseClient {
    /// `refreshable: true` adds 401 → ensureFreshSession() → retry-once on top
    /// of the M-I retry-on-5xx/429 loop. Refresh-attempt is orthogonal to the
    /// transient-retry budget (per-request flag, not consumed by 5xx retries).
    /// Anon requests pass `refreshable: false` (default) — they have no JWT
    /// to refresh.
    internal func performHTTP(
        _ request: URLRequest,
        retryable: Bool,
        refreshable: Bool = false,    // M-III addition
        label: String
    ) async throws -> (Data, HTTPURLResponse)
}
```

### 2.3 Loop semantics (M-I + M-III combined)

State per-call:
- `attempt: Int` — counts 5xx/429/transient-URLError retries (capped at `policy.maxAttempts`).
- `refreshAttempted: Bool` — at most one refresh per outer call.
- `currentRequest: URLRequest` — mutable copy; Authorization header swapped after refresh.

Decision flow on each response:
1. If `2xx/3xx` → return.
2. If `4xx` (incl. 401) AND status `== 401` AND `refreshable` AND `!refreshAttempted`:
   - Set `refreshAttempted = true`.
   - Call `try await ensureFreshSession()` (coalesces via existing `inflightFreshSessionTask`).
   - `currentRequest.setValue("Bearer \(fresh.accessToken)", forHTTPHeaderField: "Authorization")`.
   - `continue` loop **without incrementing `attempt`** (refresh-retry is its own axis).
3. If `4xx` (incl. 401 when refreshAttempted=true OR refreshable=false) → return response (caller's existing status switch + `SupabaseError.fromStatus` handles).
4. If `5xx/429/transient URLError` → existing M-I classify → retry with backoff (consumes `attempt` budget).

### 2.4 ensureFreshSession reuse

Already in `SupabaseClient.swift:112-164`. Properties:
- Coalesces parallel callers via `inflightFreshSessionTask` (line 41).
- Refreshes if `exp − now < 60s` OR `lastRefreshAt + 55min < now` (NTP-skew margin).
- Updates actor `state = .authenticated(refreshed)` + `lastRefreshAt = now()`.
- Persists rotated `refresh_token` via `sessionStore` if wired.

M-III adds **one** new caller (the retry loop) but doesn't change `ensureFreshSession` itself.

### 2.5 Authenticated vs anon callsite tagging

**Anon (pass `refreshable: false`, default — 5 callsites)**:
- `SupabaseClient.swift`:
  - `performSignInAnonymously` (line ~265) — no JWT to refresh.
  - `performTokenRefresh` (line ~313) — refreshing the refresh token; can't refresh while refreshing.
  - `resolveInvite` (line ~521) — anon endpoint.
  - `probeInvite` (line ~573) — anon endpoint.
- `SupabaseClient+Waitlist.swift`:
  - `submitToWaitlist` (line ~62) — anon.

**Anon-but-authenticated-internally (pass `refreshable: false` deliberately — 1 callsite)**:
- `SupabaseClient.swift:performRegisterPubkey` — called inside `performBootstrap` with a just-minted `accessToken`. If 401, bootstrap should fail loudly, not loop. **Mark `refreshable: false` explicitly.**

**Authenticated (pass `refreshable: true` — 16 callsites)**:
- `SupabaseClient.swift`:
  - `postInvite` (line ~423)
  - `insertWorkspaceMember` (line ~625)
- `SupabaseClient+JoinRequests.swift`:
  - `invokeCreateJoinRequest` (direct call to transport)
  - `listPendingJoinRequests` (direct)
  - `fetchOwnJoinRequest` (direct)
  - `postEdgeFunction` (shared — used by invokeCancel/Approve/Decline/DeleteInviteToken). One callsite for 4 public methods.
- `SupabaseClient+InviteTokens.swift`:
  - `insertInviteToken`, `listInviteTokens`, `markInviteTokenDeleted` (3)
- `SupabaseClient+DirectMessages.swift`:
  - `sendDirectMessage`, `fetchMessages` (shared, 3 callers), `patchDirectMessage` (shared, 2 callers), `registerAPNsToken`, `triggerAPNsPush` (5 distinct callsites at transport())
- `SupabaseClient+CrossPost.swift`:
  - `triggerSlackPost`, `triggerLinearCreate` (2)
- `SupabaseClient+CrossPostLog.swift`:
  - `fetchCrossPostLog` (1)
- `SupabaseClient+NotificationPrefs.swift`:
  - `upsertNotificationPref` (1)
- `SupabaseClient+TeamEvents.swift`:
  - `sendTeamEvent`, `fetchInboundTeamEvents` (2)
- `SupabaseClient+Workspaces.swift`:
  - `insertWorkspace`, `patchWorkspaceName`, `softDeleteWorkspace` (3)

The private `<Verb>Transport` helpers added `retryable: Bool = false` in M-I — they each gain `refreshable: Bool = false` in M-III with the same threading.

### 2.6 URLRequest mutation safety

URLRequest is a Swift value type. The retry loop holds `var currentRequest = request` (local copy). Mutation via `setValue(_:forHTTPHeaderField:)` affects only the local copy. No shared-state hazard.

The Authorization header replacement is **idempotent** at the HTTP level (PostgREST / Edge Functions read the header on each request — no caching). Other headers (apikey, Prefer, Content-Type, Content-Range) are preserved as-is.

### 2.7 Parallel-401 coalescing — already proven

The existing `inflightFreshSessionTask: Task<SupabaseAuthSession, Error>?` on the actor (SupabaseClient.swift:41) means:
- First caller's `ensureFreshSession()` invocation installs the Task.
- Second/third/Nth concurrent caller sees the installed Task and awaits it.
- One `/auth/v1/token` POST hits the wire. All callers receive the same refreshed session.
- After completion, the slot clears; subsequent calls start fresh.

M-III piggybacks on this — no new coalescing logic needed.

---

## 3. Test plan

New tests added to `SupabaseClientRetryTests.swift` (after M-I's 17 tests):

1. **`test_401WithRefreshable_callsEnsureFreshSession_andRetriesWithNewJWT`** — `[401 with old JWT, 200 with new JWT]` script + `bootstrap` returns rotated JWT on 2nd `/auth/v1/token` call. Verify (a) 2 calls to listPendingJoinRequests, (b) `/auth/v1/token` was hit ONCE during the test (refresh), (c) second listPendingJoinRequests sees the rotated Authorization Bearer.

2. **`test_401WithRefreshable_persistent401_throwsUnauthorized`** — `[401, 401]` script. Refresh fires once, second 401 returns → caller throws `.unauthorized`. Verify exactly 2 listPendingJoinRequests calls.

3. **`test_401WithRefreshable_refreshFails_propagatesError`** — refresh endpoint returns 5xx. Verify the underlying refresh error propagates (`.serverError` from `/auth/v1/token`), NOT the original 401's `.unauthorized`.

4. **`test_401WithoutRefreshable_throwsUnauthorized_singleCall`** — same as M-I task 3 test `test_getNoRetryOn401_throwsUnauthorized_singleCall` — verify behavior unchanged for `refreshable: false` paths.

5. **`test_concurrent401_sharesOneRefreshCall`** — fire 2-3 concurrent authenticated calls. All get 401 on first attempt. Verify only ONE `/auth/v1/token` POST hits the mock (via per-path call counter on the token endpoint).

---

## 4. Acceptance criteria

1. `xcodebuild` 5/5 schemes green.
2. `swift test --filter SupabaseClientRetryTests` — 22 tests pass (17 M-I + 5 new).
3. `swift test --filter SupabaseClient` — 121 baseline preserved + 5 new; only pre-existing TeamEvents drift remains.
4. All authenticated callsites pass `refreshable: true` (mechanical audit via grep against this spec §2.5 list).
5. `performRegisterPubkey` keeps `refreshable: false` (bootstrap path; explicit).
6. `/pre-push-leaf` clean.

---

## 5. Scope / non-goals

**In M-III**:
- `refreshable: Bool` param + 401 → ensureFreshSession → retry-once.
- 16 authenticated callsites tagged.
- 5 new tests.

**Out**:
- Server-side `Idempotency-Key` (M-II).
- Reader-level concurrency (M-V/M-VI).
- WorkspaceReader off-MainActor (M-IV).
- Telemetry on refresh count.

**Won't do**:
- Change `ensureFreshSession()` semantics.
- Add new `SupabaseError` cases.
- Refresh on 403 (RLS denial is a permission issue, not auth-expiry).
- Refresh more than once per `performHTTP` call (a persistent 401 means truly unauthorized — user must sign-in).
