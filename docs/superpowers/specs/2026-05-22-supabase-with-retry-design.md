# SupabaseClient `withRetry` — shared transient-failure wrapper

**Status:** Draft (2026-05-22). Phase M-I from `optimization-tier-m.md`.
**Owner:** Local Claude (Mac).
**Branch:** `feature/invite-redesign` (M-I lands as separate commit(s) on top of Tier S, parallel to dirty WIP per Anton's session-start direction).
**Cross-reference:**
- `.claude/plans/optimization-tier-m.md` — audit punch list (M-I = first row, "do M-I first — it unblocks audit confidence on the remaining ones").
- M-II (server-side idempotency + client-side `Idempotency-Key` body field on POSTs) — **separate session**, prerequisite for retrying POSTs.
- M-III (401 → `ensureFreshSession()` → retry-once with parallel-401 coalescing) — **separate session**, builds on the same `performHTTP` shim.
- Track 5 / S3 + S4 + S6 + S7 + S8 — SupabaseClient surface area that M-I instruments.

---

## 1. Goal — fitness function

The retry wrapper is **done** when:

1. **Tunnel reconnect / 502 / Supabase cold-start mid-tick** auto-recovers on `GET` and idempotent `PATCH` paths instead of bubbling "Network error" to UI.
2. **30s sidebar / pending-requests polls** survive a single transient 5xx without flicker `loading → loaded` failure state.
3. **`Retry-After: N` on 429** (header OR `{"retry_after_seconds": N}` body field, Slack/Edge pattern) is honored — wrapper waits exactly N seconds before next attempt (not the schedule).
4. **POSTs are NOT auto-retried** in M-I (would risk double-mutate on `invite_tokens.used_count` / decline-of-declined audit churn). Per Anton's session direction: POST = pass-through. Lift to retry in M-II after server-side dedup lands.
5. **401 is NOT auto-handled** in M-I (M-III's job — needs `ensureFreshSession()` callback + `inflightFreshSessionTask` coalescing). 401 passes through as `.unauthorized` today.
6. **No public API changes.** All `SupabaseClient` methods keep same signatures, same error types. Wrapper is internal implementation detail.
7. **No regressions** in existing 15 `SupabaseClient*Tests.swift` files; baseline SPM count preserved + ~8-10 net new retry-specific tests.
8. **Pure classifier** unit-testable without HTTP wire — given `(HTTPURLResponse?, URLError?, attempt, policy, hint)` returns `RetryDecision`. Trivial to extend.
9. **Test injection point** for clock — retry tests skip real `Task.sleep` via injected `@Sendable (Duration) async throws -> Void`. Production keeps `Task.sleep(for:)` default (cancellation-aware).

---

## 2. Architecture

### 2.1 Files

**New** (2 source + 1 test):
- `Packages/LeafCore/Sources/LeafCore/Network/RetryPolicy.swift` — pure value type + classifier (`Sendable` struct + free function).
- `Packages/LeafCore/Sources/LeafCore/Network/SupabaseClient+Retry.swift` — internal `performHTTP(_:retryable:label:)` method on the actor; owns the retry loop.
- `Packages/LeafCore/Tests/LeafCoreTests/SupabaseClientRetryTests.swift` — retry-loop integration tests using existing `MockURLProtocol`.

**Modified** (10 transport-helper sites — each delta is 1-3 lines):
- `Packages/LeafCore/Sources/LeafCore/Network/SupabaseClient.swift` — 5 callsites:
  - `decodeAuthResponse(request:label:)` lines 268-309 — used by `performSignInAnonymously` (POST, `retryable=false`) and `performTokenRefresh` (POST, `retryable=false`). Both stay one-shot.
  - `performRegisterPubkey` lines 329-355 — POST, `retryable=false`.
  - `postInvite` lines 423-491 — POST, `retryable=false`.
  - `resolveInvite` + `probeInvite` lines 521-611 — POST to Edge, `retryable=false`.
  - `insertWorkspaceMember` lines 625-656 — POST, `retryable=false`.
- `Packages/LeafCore/Sources/LeafCore/Network/SupabaseClient+JoinRequests.swift`:
  - `joinRequestsTransport` lines 160-174 — now thin delegate to `performHTTP`.
  - 5 Edge POSTs (`invokeCreateJoinRequest` / `invokeCancelJoinRequest` / `invokeApproveJoinRequest` / `invokeDeclineJoinRequest` / `invokeDeleteInviteToken`) — `retryable=false`.
  - 2 REST GETs (`listPendingJoinRequests` / `fetchOwnJoinRequest`) — `retryable=true`.
- `Packages/LeafCore/Sources/LeafCore/Network/SupabaseClient+InviteTokens.swift`:
  - `inviteTokensTransport` lines 186-200 — delegate.
  - `insertInviteToken` POST → `retryable=false`.
  - `listInviteTokens` GET → `retryable=true`.
  - `markInviteTokenDeleted` PATCH → `retryable=true` (idempotent — same SET clause on retry).
- `Packages/LeafCore/Sources/LeafCore/Network/SupabaseClient+DirectMessages.swift`:
  - `transport` lines 423-434 — delegate.
  - 1 POST (`sendDirectMessage`) → `retryable=false`. 3 GETs (`fetchInboundMessages` / `fetchOutboundMessages` / `fetchMessageByID`) → `true`. 2 PATCHes (`markRead` / `markDone`) → `true`. UPSERT-style POST (`registerAPNsToken`) → `retryable=false` (POST scope). Edge POST (`triggerAPNsPush`) → `retryable=false`.
- `Packages/LeafCore/Sources/LeafCore/Network/SupabaseClient+CrossPost.swift`:
  - `crossPostTransport` lines 233-244 — delegate.
  - Both Edge POSTs (`triggerSlackPost` / `triggerLinearCreate`) → `retryable=false`. Linear's existing `idempotency_key` in body field is left in place but does NOT enable retry in M-I (out of scope; flip in M-II).
- `Packages/LeafCore/Sources/LeafCore/Network/SupabaseClient+Workspaces.swift`:
  - `workspacesTransport` lines 176-190 — delegate.
  - `insertWorkspace` POST → `retryable=false`. `patchWorkspaceName` / `softDeleteWorkspace` PATCHes → `retryable=true`. **`Content-Range` 0-rows-affected detection** stays inside the helper — wrapper returns the 200/204 response untouched and helper still inspects the header.
- `Packages/LeafCore/Sources/LeafCore/Network/SupabaseClient+CrossPostLog.swift`:
  - GET `fetchCrossPostLog` → `retryable=true`.
- `Packages/LeafCore/Sources/LeafCore/Network/SupabaseClient+NotificationPrefs.swift`:
  - `upsertNotificationPref` (POST with merge-duplicates) → `retryable=false` (POST scope; despite UPSERT idempotency, M-I treats verb as POST).
- `Packages/LeafCore/Sources/LeafCore/Network/SupabaseClient+TeamEvents.swift`:
  - `sendTeamEvent` POST → `retryable=false`. GET → `retryable=true`.
- `Packages/LeafCore/Sources/LeafCore/Network/SupabaseClient+Waitlist.swift`:
  - `submitToWaitlist` POST → `retryable=false`.

**Untouched**:
- `SupabaseError.swift` — wrapper rethrows existing cases (`.transport(reason:)` / `.serverError` / `.rateLimited` / etc.). No new cases.
- Public surface of every method.
- `MockURLProtocol` — retry tests use existing `MockURLProtocol.handler` closure mechanism, with the closure inspecting a per-test call counter to return scripted responses (no MockURLProtocol changes needed).
- `SupabaseClient` actor properties / public init (clock injection is via NEW optional init param with safe default — see §4).

### 2.2 Public contract

```swift
extension SupabaseClient {
    /// Internal HTTP gateway. All transport helpers in the 10 extensions
    /// delegate here. Retries transient failures on `retryable=true`
    /// callers per `self.retryPolicy`; passes through immediately on
    /// `retryable=false`. On exhaustion returns the last response (so
    /// caller's existing status-code switch + `SupabaseError.fromStatus`
    /// path remains the single source of error mapping).
    ///
    /// - Parameter retryable: `true` for idempotent verbs (GET, PATCH on
    ///   same-row SET clauses). `false` for POST until M-II ships
    ///   server-side `Idempotency-Key` dedup table.
    /// - Parameter label: stable string for `.transport(reason:)`
    ///   diagnostics (kept compatible with existing helper labels).
    internal func performHTTP(
        _ request: URLRequest,
        retryable: Bool,
        label: String
    ) async throws -> (Data, HTTPURLResponse)
}
```

### 2.3 RetryPolicy value type

```swift
public struct RetryPolicy: Sendable, Equatable {
    /// Total attempts including the first. `4` = initial + 3 retries.
    public let maxAttempts: Int
    /// Pre-attempt delays. `delays[i]` = wait BEFORE attempt `i+1`.
    /// `delays.count` should be `maxAttempts - 1`.
    public let delays: [Duration]
    /// Jitter band as a fraction of `delays[i]`. `0.25` = ±25%.
    public let jitterFraction: Double

    public static let `default` = RetryPolicy(
        maxAttempts: 4,
        delays: [.milliseconds(200), .seconds(1), .seconds(3)],
        jitterFraction: 0.25
    )
}
```

Default schedule: 200ms / 1s / 3s + ±25% jitter. Max ~4.2s wait. Conservative — designed for tunnel-reconnect / Supabase cold-start (typically <2s).

### 2.4 Classifier (pure)

```swift
enum RetryDecision: Sendable, Equatable {
    case giveUp                                  // exhausted OR non-retryable
    case retry(after: Duration)
}

/// Pure. No I/O, no Date(). All inputs explicit.
func classify(
    response: HTTPURLResponse?,
    error: URLError?,
    attempt: Int,                                // 0-indexed, BEFORE incrementing
    policy: RetryPolicy,
    retryAfterHint: Duration?,                   // already-parsed Retry-After
    nextDelayJitterMultiplier: Double            // 1.0 + rand(-jitter, +jitter); injected for determinism
) -> RetryDecision
```

Decision matrix:

| Input | `.retry(after:)` | `.giveUp` |
|---|---|---|
| `attempt + 1 >= policy.maxAttempts` | — | always |
| `error?.code` ∈ {`.timedOut`, `.networkConnectionLost`, `.notConnectedToInternet`, `.dnsLookupFailed`, `.cannotConnectToHost`, `.cannotFindHost`, `.networkUnreachable`} | retry with `policy.delays[attempt] * multiplier` | — |
| `error?.code` ∈ {`.cancelled`, `.userCancelledAuthentication`, `.secureConnectionFailed`, `.clientCertificateRejected`, `.badServerResponse`} | — | always |
| `response.statusCode == 429` | retry with `retryAfterHint` if present, else `policy.delays[attempt] * multiplier` | — |
| `response.statusCode` ∈ {500, 502, 503, 504, 505, 506, 507, 508, 510, 511} | retry with `policy.delays[attempt] * multiplier` | — |
| `response.statusCode == 501` | — | always (Not Implemented = permanent) |
| `response.statusCode` ∈ 2xx, 3xx, 4xx (incl. 401, 403, 404, 409, 410, 422) | — | always (success or permanent client error) |
| Any other `URLError` not listed above | — | always (conservative) |

### 2.5 Retry-After parsing

Helper inside `performHTTP`:

```swift
private func parseRetryAfter(headers: HTTPURLResponse, body: Data) -> Duration? {
    // Priority 1: Retry-After header in seconds.
    if let h = headers.value(forHTTPHeaderField: "Retry-After"),
       let secs = Double(h) {
        return .milliseconds(Int(secs * 1000))
    }
    // Priority 2: Edge-function pattern: {"retry_after_seconds": N}.
    if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
       let secs = obj["retry_after_seconds"] as? Double {
        return .milliseconds(Int(secs * 1000))
    }
    // HTTP-date format intentionally not supported (Supabase / Cloudflare
    // both emit numeric Retry-After). Falls through to schedule.
    return nil
}
```

Only invoked on 429 paths to keep hot loop cheap.

### 2.6 Loop sketch

```swift
internal func performHTTP(
    _ request: URLRequest,
    retryable: Bool,
    label: String
) async throws -> (Data, HTTPURLResponse) {
    if !retryable {
        // Pass-through preserves M-I scope contract (POST = no retry).
        return try await performOneShot(request, label: label)
    }
    var attempt = 0
    while true {
        let outcome: OneShotOutcome
        do {
            let (data, resp) = try await performOneShot(request, label: label)
            outcome = .response(data: data, response: resp)
        } catch let urlError as URLError {
            outcome = .urlError(urlError)
        }
        // catch CancellationError separately if Task.sleep was cancelled mid-wait — propagate.
        // ... (see §3 for full path)

        let retryAfterHint: Duration? = outcome.responseFor429.flatMap {
            parseRetryAfter(headers: $0.response, body: $0.data)
        }
        let multiplier = 1.0 + Double.random(in: -policy.jitterFraction ... +policy.jitterFraction)
        let decision = classify(
            response: outcome.httpResponse,
            error: outcome.urlError,
            attempt: attempt,
            policy: retryPolicy,
            retryAfterHint: retryAfterHint,
            nextDelayJitterMultiplier: multiplier
        )
        switch decision {
        case .giveUp:
            return try outcome.surfaceOrThrow()      // returns response OR rethrows URLError
        case .retry(let delay):
            try await sleep(delay)                   // injected; cancellation-aware
            attempt += 1
        }
    }
}

private enum OneShotOutcome {
    case response(data: Data, response: HTTPURLResponse)
    case urlError(URLError)
    // ... helpers
}
```

`performOneShot` wraps the existing `urlSession.data(for:)` + non-http guard + transport-error path — basically inlines what each of the 9 existing transport helpers does today.

---

## 3. Clock injection (test determinism)

`SupabaseClient` init gains an optional parameter — backwards-compatible default invokes real `Task.sleep`:

```swift
public init(
    baseURL: URL,
    anonKey: String,
    urlSession: URLSession = .shared,
    identity: @escaping @Sendable () throws -> Curve25519.KeyAgreement.PrivateKey,
    now: @escaping @Sendable () -> Date = { Date() },
    sessionStore: SupabaseSessionStore? = nil,
    retryPolicy: RetryPolicy = .default,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
)
```

- Production: default — cancellation-aware `Task.sleep(for:)`.
- Tests: `{ _ in /* no-op */ }` to skip waits entirely (verify call sequencing, not wall-clock).
- Inspector tests for delay magnitude: `{ duration in await someActor.record(duration) }` to capture passed durations.

All 15 existing test files use the public init without `retryPolicy` / `sleep` — default args keep them green.

---

## 4. Test plan

New file `Packages/LeafCore/Tests/LeafCoreTests/SupabaseClientRetryTests.swift` covering:

**Pure classifier** (no actor, no URLSession):
1. `classify_returns_giveUp_when_attempt_at_max` — boundary.
2. `classify_returns_retry_on_502_503_504_with_schedule_delay`.
3. `classify_returns_giveUp_on_501_not_implemented`.
4. `classify_returns_retry_on_429_with_retryAfterHint_overrides_schedule`.
5. `classify_returns_retry_on_429_without_hint_uses_schedule`.
6. `classify_returns_retry_on_urlError_timedOut_networkConnectionLost_dnsLookupFailed`.
7. `classify_returns_giveUp_on_urlError_cancelled_secureConnectionFailed`.
8. `classify_returns_giveUp_on_4xx_including_401_403_404_409_410_422`.
9. `classify_applies_jitterMultiplier_to_schedule_delay_but_not_to_retryAfterHint`.

**Integration via MockURLProtocol** (actor + URLSession + injected `sleep` no-op):
10. `getRetriesOnTransient502_succeedsOnThirdAttempt` — script: `[502, 502, 200]`. Verifies `MockURLProtocol` was called 3 times, method returned success.
11. `getExhaustsOn503AcrossFourAttempts_throwsServerError` — script: `[503, 503, 503, 503]`. Verifies 4 calls, throws `.serverError`.
12. `patchRetriesOnNetworkConnectionLost_succeedsOnRetry` — first call throws `URLError(.networkConnectionLost)`, second returns 200. Verifies 2 calls.
13. `get429HonorsRetryAfterHeader` — script: `[(429, {"Retry-After": "2"}), (200, _)]`. Capture sleep durations via inspector; verify `[2000ms ± 0]` (no jitter applied to hints).
14. `get429HonorsRetryAfterBodyField` — script: `[(429, body: {"retry_after_seconds": 1}), (200, _)]`. Verify capture `[1000ms]`.
15. `postNotRetriedOn502_throwsServerError_singleCall` — verifies POST scope: `[502]` script → 1 call, throws `.serverError`.
16. `getNoRetryOn401_throwsUnauthorized_singleCall` — M-III hasn't shipped; 401 passes through.
17. `getNoRetryOn404_throwsNotFound_singleCall` — permanent.
18. `taskCancellation_propagatesDuringSleep` — outer Task cancelled mid-wait via injected sleep that throws `CancellationError`; verify `CancellationError` surfaces, no further URLSession call.
19. `taskCancellation_propagatesDuringRequest` — `URLError(.cancelled)` during attempt; verify `.transport` thrown immediately, no retry.

**Existing regression**:
- Run full `Packages/LeafCore` SPM suite. All `SupabaseClient*Tests.swift` (15 files) must remain green with zero modifications.

---

## 5. Acceptance criteria

1. `xcodebuild -scheme Leaf -configuration Debug build` — green.
2. `xcodebuild` 5/5 schemes (per Track 5 convention): `Leaf`, `LeafAgent`, `LeafMCPServer`, `LeafCore` (Mac), `LeafCorePrivate`.
3. `swift test --package-path Packages/LeafCore` — baseline SPM count + ~10 net new retry tests, zero existing-test regressions.
4. `swift test --filter SupabaseClientRetryTests` — all 19 scenarios pass.
5. **Manual smoke** (best-effort against live Supabase if available, otherwise via MockURLProtocol harness):
   - Wifi off → 1 sec → on → during a sidebar refresh tick: see DataPattern recover instead of throwing "Network error". GET on `join_requests` should silently retry.
   - Synthetic 429 via Edge-function early-return for testing — verify Retry-After respected (or skip if env unavailable).
6. `/pre-push-leaf` — no moat leaks (retry classifier is generic pattern, not Leaf-specific implementation detail; safe for public repo).

---

## 6. Scope / non-goals

**In M-I**:
- Retry wrapper, classifier, schedule + jitter + Retry-After parsing.
- Refactor of 10 transport helpers to delegate to `performHTTP`.
- Test infrastructure for retry scenarios.

**Out of M-I** (separate phases per `optimization-tier-m.md`):
- M-II — `Idempotency-Key` body field on POSTs + server-side `decision_log(idempotency_key) PRIMARY KEY` dedup table → enables POST retry.
- M-III — `once-on-401` retry via `ensureFreshSession()` + parallel-401 coalescing through `inflightFreshSessionTask`.
- M-IV — `WorkspaceReader.refresh()` off MainActor.
- M-V — `TaskGroup` parallelisation of `approveAll` / `declineAll`.
- M-VI — last-write-wins coalescing in Reader detached Tasks.

**Won't do in M-I**:
- Change public method signatures.
- Introduce new `SupabaseError` cases.
- Refactor `inflightFreshSessionTask` pattern (kept for M-III).
- Change `MockURLProtocol` (closure-based handler already flexible enough for scripted scenarios).
- Honor HTTP-date format `Retry-After` (Supabase / Cloudflare both emit numeric).

---

## 7. Open questions

None blocking. Future considerations (carry to follow-up sessions, not M-I):

- **Q1.** Should retry budget be per-request OR per-actor (rate limiter shared across concurrent calls)? Per-request keeps M-I simple; consider in M-V when `TaskGroup` semaphore semantics arrive.
- **Q2.** Should classifier be public (so leaf-relay / other modules can reuse)? Keep `internal` in M-I; expose only if a second module demands.
- **Q3.** Telemetry: should we emit a metric `supabase_retry_count{method,status}` for observability? Out of scope for M-I (no metrics substrate today); revisit when telemetry track lands.

---

## 8. Verification checklist

- [ ] Build green: 5/5 xcodebuild schemes.
- [ ] SPM tests: baseline preserved + 19 new retry tests pass.
- [ ] `superpowers:code-reviewer` subagent independent review against this spec.
- [ ] `/pre-push-leaf` clean (generic retry pattern, no moat).
- [ ] Manual smoke (best-effort on real Supabase): WiFi blink during sidebar tick → recovers.
- [ ] Commit decomposition matches Stage 8 plan (one commit per logical unit: classifier + policy → performHTTP shim → 10 helper migrations → tests).
