//
//  SupabaseClient+Retry.swift
//  LeafCore
//
//  Phase M-I (optimization-tier-m.md). Shared transport gateway used by
//  every transport helper in the 10 SupabaseClient+*.swift extensions.
//  On `retryable=true` runs the retry loop per `self.retryPolicy`. On
//  `retryable=false` performs exactly one HTTP attempt and surfaces the
//  outcome as-is. POSTs always pass `false` in M-I (M-II adds server-side
//  Idempotency-Key dedup that makes POST retries safe).
//

import Foundation

extension SupabaseClient {
  /// Internal HTTP gateway. See spec §2.2.
  ///
  /// - `retryable: false` → one attempt; existing pass-through semantics.
  /// - `retryable: true`  → loop per `self.retryPolicy`; honors Retry-After
  ///   header AND `{"retry_after_seconds": N}` body field on 429.
  ///
  /// On exhaustion of the retry budget the LAST attempt's response is
  /// returned (caller's existing `guard http.statusCode == 200` switch then
  /// throws `.serverError` / `.rateLimited` via `SupabaseError.fromStatus`).
  /// On URLError exhaustion this throws `SupabaseError.transport(reason:)`.
  /// `CancellationError` from injected `sleep` propagates as-is.
  internal func performHTTP(
    _ request: URLRequest,
    retryable: Bool,
    refreshable: Bool = false,
    idempotent: Bool = false,
    label: String
  ) async throws -> (Data, HTTPURLResponse) {
    if !retryable && !refreshable {
      // One-shot path: still needs idempotency-key injection if requested.
      if idempotent {
        var req = request
        req.setValue(
          UUID().uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
        return try await performOneShot(req, label: label)
      }
      return try await performOneShot(request, label: label)
    }
    // Retry loop. Calls urlSession.data(for:) directly (bypassing
    // performOneShot's .transport wrapping) so the URLError catch branch
    // sees the raw URLError for classifier dispatch.
    //
    // M-II state: when `idempotent=true`, generate ONE UUID before the loop
    // and set it as Idempotency-Key. The key survives every M-I retry
    // attempt AND the M-III Authorization swap (which only touches the
    // Authorization header, never Idempotency-Key).
    //
    // M-III state: `refreshAttempted` flag bounds 401-refresh to at most one
    // per outer call. `currentRequest` is a mutable copy whose Authorization
    // header is swapped after a successful refresh. The flag is orthogonal
    // to the M-I `attempt` budget — refresh-retry doesn't consume it.
    var attempt = 0
    var refreshAttempted = false
    var currentRequest = request
    if idempotent {
      currentRequest.setValue(
        UUID().uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
    }
    while attempt < retryPolicy.maxAttempts {
      do {
        let (data, response) = try await urlSession.data(for: currentRequest)
        guard let http = response as? HTTPURLResponse else {
          throw SupabaseError.transport(reason: "\(label): non-http")
        }
        // M-III — 401 auto-refresh path (orthogonal to retryable budget).
        // `force: true` bypasses ensureFreshSession's local shouldRefresh
        // heuristic — a 401 from the server is authoritative proof that
        // the cached JWT is rejected, regardless of exp/NTP-skew margin.
        if refreshable, http.statusCode == 401, !refreshAttempted {
          refreshAttempted = true
          let fresh = try await ensureFreshSession(force: true)
          currentRequest.setValue(
            "Bearer \(fresh.accessToken)", forHTTPHeaderField: "Authorization")
          continue  // re-attempt with new JWT; do NOT increment attempt
        }
        // For non-retryable callers, return the response immediately so
        // their existing status-code switch handles 4xx/5xx mapping. This
        // covers the refreshable=true + retryable=false combination
        // (most authenticated POSTs in M-I scope).
        if !retryable {
          return (data, http)
        }
        let hint: Duration? =
          (http.statusCode == 429)
          ? parseRetryAfter(headers: http, body: data)
          : nil
        let jitterLow = -retryPolicy.jitterFraction
        let jitterHigh = retryPolicy.jitterFraction
        let multiplier = 1.0 + Double.random(in: jitterLow...jitterHigh)
        let decision = classify(
          response: http,
          error: nil,
          attempt: attempt,
          policy: retryPolicy,
          retryAfterHint: hint,
          nextDelayJitterMultiplier: multiplier
        )
        switch decision {
        case .giveUp:
          return (data, http)
        case .retry(let delay):
          try await sleep(delay)
          attempt += 1
          continue
        }
      } catch let urlError as URLError {
        // Independent-review IMPORTANT — distinguish outer Task cancellation
        // (where the surrounding Task is cancelled and URLSession surfaces
        // `URLError(.cancelled)`) from genuine connection-cancelled errors.
        // Without this, a user-cancelled tick masquerades as `.transport`
        // instead of `CancellationError`, losing observability.
        try Task.checkCancellation()
        let jitterLow = -retryPolicy.jitterFraction
        let jitterHigh = retryPolicy.jitterFraction
        let multiplier = 1.0 + Double.random(in: jitterLow...jitterHigh)
        let decision = classify(
          response: nil,
          error: urlError,
          attempt: attempt,
          policy: retryPolicy,
          retryAfterHint: nil,
          nextDelayJitterMultiplier: multiplier
        )
        switch decision {
        case .giveUp:
          throw SupabaseError.transport(reason: "\(label): \(urlError)")
        case .retry(let delay):
          try await sleep(delay)
          attempt += 1
          continue
        }
      }
      // Note: CancellationError propagates naturally out of `try await
      // sleep(...)` and `try await urlSession.data(for:)` — neither
      // matches `as URLError`, so it escapes the catch chain unchanged.
    }
    // Unreachable in practice (decision .giveUp returns/throws inside loop);
    // defensive fallback.
    throw SupabaseError.transport(reason: "\(label): retry budget exhausted")
  }

  /// One HTTP attempt. Surfaces URLSession.data(for:) outcomes via the
  /// same error shape every existing transport helper used today:
  /// network error → SupabaseError.transport, non-HTTPURLResponse →
  /// SupabaseError.transport, otherwise return (data, http) for the
  /// caller's status-code switch.
  internal func performOneShot(
    _ request: URLRequest,
    label: String
  ) async throws -> (Data, HTTPURLResponse) {
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await urlSession.data(for: request)
    } catch {
      throw SupabaseError.transport(reason: "\(label): \(error)")
    }
    guard let http = response as? HTTPURLResponse else {
      throw SupabaseError.transport(reason: "\(label): non-http")
    }
    return (data, http)
  }

  /// Parses `Retry-After: N` HTTP header (seconds), falling back to JSON
  /// body field `{"retry_after_seconds": N}` (Slack/Edge convention used
  /// by `triggerSlackPost`). HTTP-date format intentionally unsupported
  /// (Supabase / Cloudflare both emit numeric Retry-After).
  internal func parseRetryAfter(headers: HTTPURLResponse, body: Data) -> Duration? {
    if let h = headers.value(forHTTPHeaderField: "Retry-After"),
      let secs = Double(h)
    {
      return .milliseconds(Int(secs * 1000))
    }
    if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
      let secs = obj["retry_after_seconds"] as? Double
    {
      return .milliseconds(Int(secs * 1000))
    }
    return nil
  }
}

// MARK: - DEBUG test-only passthroughs (M-II idempotency tests)

#if DEBUG
  extension SupabaseClient {
    /// Exposes `performHTTP` to idempotency tests (actor-internal method).
    internal func _performHTTPForTesting(
      _ request: URLRequest,
      retryable: Bool,
      refreshable: Bool = false,
      idempotent: Bool = false,
      label: String
    ) async throws -> (Data, HTTPURLResponse) {
      try await performHTTP(
        request, retryable: retryable, refreshable: refreshable,
        idempotent: idempotent, label: label)
    }

    /// Exposes `ensureFreshSession(force:)` for the refresh+key-preservation
    /// test (#10) — lets tests force a token refresh from the outside.
    internal func _forceRefreshForTesting() async throws -> SupabaseAuthSession {
      try await ensureFreshSession(force: true)
    }
  }
#endif
