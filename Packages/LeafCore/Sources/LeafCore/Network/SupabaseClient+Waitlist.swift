//
//  SupabaseClient+Waitlist.swift
//  LeafCore
//
//  Track 5 / S8 / T4 — anonymous waitlist email capture from UpgradeModal.
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
//  email INSERT returns 409 (PostgreSQL unique_violation). Client treats 409
//  as success (`.success(())`) so the UpgradeModal flow surfaces "Thanks —
//  we'll be in touch!" on both first-time AND retry submits.
//

import Foundation

extension SupabaseClient {

  /// T4 — anonymous waitlist email capture. RLS `WITH CHECK true` on
  /// `waitlist` accepts the insert with anon `apikey`-only auth.
  ///
  /// Returns:
  /// - `.success(())` on HTTP 201 (new row) OR 409 (duplicate email = idempotent).
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

    let url = SupabaseEndpoint.waitlistInsert(baseURL: baseURL)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    // Anon flow: apikey-only, no Authorization header. The waitlist RLS
    // policy is `WITH CHECK (true)`; PostgREST still requires the apikey
    // gateway header on every request (Supabase Kong layer).
    // `Prefer: return=minimal` avoids the round-tripped row body (we don't
    // need it — the modal only branches on success/failure of the insert).
    var headers = SupabaseEndpoint.anonHeaders(anonKey: anonKey)
    headers["Prefer"] = "return=minimal"
    for (k, v) in headers {
      request.setValue(v, forHTTPHeaderField: k)
    }

    let body: [String: Any] = [
      "email": normalizedEmail,
      "source": source,
    ]
    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    } catch {
      return .failure(SupabaseError.decoding(reason: "submitToWaitlist: encode body: \(error)"))
    }

    let data: Data
    let http: HTTPURLResponse
    do {
      (data, http) = try await performHTTP(
        request, retryable: false, label: "submitToWaitlist")
    } catch let e as SupabaseError {
      return .failure(e)
    } catch {
      return .failure(SupabaseError.transport(reason: "submitToWaitlist: \(error)"))
    }

    // 201 Created — fresh INSERT.
    // 204 No Content — also success when `Prefer: return=minimal` is set and
    //                  the server collapses the response body.
    // 409 Conflict   — duplicate email; idempotent success per spec §10.3.
    switch http.statusCode {
    case 200, 201, 204:
      return .success(())
    case 409:
      return .success(())
    default:
      return .failure(SupabaseError.fromStatus(http.statusCode, body: data))
    }
  }
}

// MARK: - SupabaseEndpoint extension (waitlist path)

extension SupabaseEndpoint {
  /// POST /rest/v1/waitlist — anon-INSERT-only (RLS WITH CHECK true).
  public static func waitlistInsert(baseURL: URL) -> URL {
    baseURL.appendingPathComponent("rest/v1/waitlist")
  }
}
