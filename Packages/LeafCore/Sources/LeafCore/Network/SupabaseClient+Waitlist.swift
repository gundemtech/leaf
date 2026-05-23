//
//  SupabaseClient+Waitlist.swift
//  LeafCore
//
//  Track 5 / S8 / T4 — anonymous waitlist email capture from UpgradeModal.
//
//  M-II — rewritten to call `submit_waitlist` Edge Function
//  (functions/v1/submit_waitlist). The Edge Function is ANON — no JWT required
//  (ownerPubkey=null in checkIdempotency, same pattern as invite_resolve).
//  Idempotency-Key is still injected (idempotent:true) because the anon
//  endpoint honors the header for deterministic dedup of retry storms.
//
//  Per T2 migration `20260519120000_s8_substrate.sql`:
//      CREATE POLICY waitlist_anon_insert ON waitlist
//          FOR INSERT WITH CHECK (true);
//  No SELECT policy → reads denied; service_role bypasses RLS for ops export.
//
//  Anonymous in two senses:
//    1. No JWT required — anon `apikey` header is the only auth Supabase needs
//       to satisfy RLS WITH CHECK (true). We deliberately do NOT call
//       `ensureAuthenticated()` so a fresh-install Free-tier user without any
//       session yet can submit email.
//    2. Email-only payload — no pubkey association, no per-user metrics
//       (spec §10.3 + §15).
//
//  409 idempotency: the `email` PK CHECK regex enforces basic shape; duplicate
//  email INSERT returns 409 `waitlist_exists`. Client treats 409 as success
//  so the UpgradeModal flow surfaces "Thanks — we'll be in touch!" on both
//  first-time AND retry submits.
//

import Foundation

extension SupabaseClient {

  /// T4 / M-II — anonymous waitlist email capture via `submit_waitlist` Edge Fn.
  /// ANON flow: no Authorization header, no `ensureAuthenticated()`.
  /// Idempotency-Key is injected (idempotent:true) for deterministic dedup.
  ///
  /// Returns:
  /// - `.success(())` on HTTP 201 (new row) OR 409 waitlist_exists (idempotent).
  /// - `.failure(SupabaseError)` on other 4xx/5xx OR transport error.
  ///
  /// Result-typed instead of throws because the call site is a closure
  /// passed into `UpgradeModal.onSubmitEmail` (which declares
  /// `(String) async -> Result<Void, Error>`). No throws → no upstream
  /// try-catch boilerplate in the SwiftUI view.
  public func submitToWaitlist(
    email: String,
    source: String = "upgrade_modal"
  ) async -> Result<Void, Error> {
    // Trim + lowercase locally (table CHECK regex is case-insensitive `~*`,
    // but normalizing client-side keeps the PK collision logic predictable
    // for downstream ops querying via service_role).
    let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedEmail = trimmed.lowercased()
    guard !normalizedEmail.isEmpty else {
      return .failure(SupabaseError.badRequest)
    }

    let url = SupabaseEndpoint.submitWaitlistEdge(baseURL: baseURL)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    // ANON flow: apikey-only, no Authorization header. The Edge Function is
    // ownerPubkey=null (same as invite_resolve). Supabase Kong layer still
    // requires the `apikey` header on every request.
    for (k, v) in SupabaseEndpoint.anonHeaders(anonKey: anonKey) {
      request.setValue(v, forHTTPHeaderField: k)
    }

    let createdAtMs = Int64(Date().timeIntervalSince1970 * 1000)
    let body: [String: Any] = [
      "email": normalizedEmail,
      "source": source,
      "created_at_ms": createdAtMs,
    ]
    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    } catch {
      return .failure(SupabaseError.decoding(reason: "submitToWaitlist: encode body: \(error)"))
    }

    let data: Data
    let http: HTTPURLResponse
    do {
      // idempotent:true injects Idempotency-Key; retryable:true is safe here
      // because the Edge Function's server-side dedup makes every retry
      // idempotent. refreshable:false — anon path has no JWT to refresh.
      (data, http) = try await performHTTP(
        request, retryable: true, refreshable: false, idempotent: true,
        label: "submitToWaitlist")
    } catch let e as SupabaseError {
      return .failure(e)
    } catch {
      return .failure(SupabaseError.transport(reason: "submitToWaitlist: \(error)"))
    }

    // 201 Created — fresh INSERT.
    // 409 waitlist_exists — duplicate email; idempotent success per spec §10.3.
    switch http.statusCode {
    case 200, 201:
      return .success(())
    case 409:
      return .success(())
    default:
      return .failure(SupabaseError.fromStatus(http.statusCode, body: data))
    }
  }
}
