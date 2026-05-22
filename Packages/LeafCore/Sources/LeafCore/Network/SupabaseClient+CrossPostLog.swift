//
//  SupabaseClient+CrossPostLog.swift
//  LeafCore
//
//  Track 5 / S7 C.7 — Batch-fetch cross_post_log rows from Supabase PostgREST.
//
//  Used by CrossPostLogReader to populate its cache for a given set of
//  direct_message IDs. RLS policy `cross_post_log_party_read` (shipped in S6)
//  gates results to rows where the authenticated pubkey matches the sender OR
//  recipient of the corresponding DM.
//

import Foundation

extension SupabaseClient {

  /// Batch-fetch cross_post_log rows for the given message IDs.
  ///
  /// - Parameter messageIDs: UUIDs of direct_messages rows whose cross-post
  ///   log entries should be fetched. Must be non-empty (caller guard required —
  ///   passing empty returns [] without a network call).
  /// - Returns: Decoded `[CrossPostLogRow]`, ordered by PostgREST default
  ///   (creation order). Empty array on success with no matching rows.
  /// - Throws: `SupabaseError.transport` on network failure,
  ///   `SupabaseError.decoding` on JSON parse / HTTPS-invariant violation,
  ///   or any `SupabaseError` status mapping for non-200 HTTP responses.
  public func fetchCrossPostLog(messageIDs: [String]) async throws -> [CrossPostLogRow] {
    guard !messageIDs.isEmpty else { return [] }

    let session = try await ensureAuthenticated()

    let url = SupabaseEndpoint.crossPostLogByMessageIDs(messageIDs, baseURL: baseURL)
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    for (k, v) in SupabaseEndpoint.authenticatedHeaders(
      anonKey: anonKey, accessToken: session.accessToken
    ) {
      request.setValue(v, forHTTPHeaderField: k)
    }

    let (data, http) = try await performHTTP(
      request, retryable: true, refreshable: true, label: "fetchCrossPostLog")
    guard http.statusCode == 200 else {
      throw SupabaseError.fromStatus(http.statusCode, body: data)
    }
    do {
      return try JSONDecoder().decode([CrossPostLogRow].self, from: data)
    } catch {
      throw SupabaseError.decoding(reason: "fetchCrossPostLog: \(error)")
    }
  }
}
