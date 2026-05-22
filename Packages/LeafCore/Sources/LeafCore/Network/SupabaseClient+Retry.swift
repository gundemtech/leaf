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
  /// Returns the FINAL response (data, http) to the caller for its existing
  /// status-code switch + SupabaseError.fromStatus path. On exhaustion of
  /// retries the last response IS returned (caller throws `.serverError`
  /// or `.rateLimited` via fromStatus). On URLError exhaustion this throws
  /// `SupabaseError.transport(reason:)`.
  internal func performHTTP(
    _ request: URLRequest,
    retryable: Bool,
    label: String
  ) async throws -> (Data, HTTPURLResponse) {
    if !retryable {
      return try await performOneShot(request, label: label)
    }
    // Retry loop wired in Task 3; for Task 2 the scaffold is one-shot only
    // so we can verify the POST pass-through path independently.
    return try await performOneShot(request, label: label)
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
}
