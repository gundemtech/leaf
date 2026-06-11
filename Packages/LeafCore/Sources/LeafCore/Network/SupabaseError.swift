//
//  SupabaseError.swift
//  LeafCore
//
//  Track 5 / S3 — wire error mapping for SupabaseClient. Caller layers
//  (InviteService / InviteAcceptService) translate to LeafError cases.
//

import Foundation

public enum SupabaseError: Error, Sendable, Equatable {
  case badRequest
  case unauthorized
  case forbidden  // I3 — 403 from PostgREST RLS denial
  case notFound
  case conflict
  case rateLimited
  case serverError
  case authBootstrapFailed(reason: String)
  case identityClaimMissing  // I1 — session has no pubkey claim (Auth Hook race / JWT decode glitch)
  case inviteNotResolvable  // 404 from invite_resolve — token claimed/expired/missing
  case pubkeyAlreadyRegistered  // 409 from register_pubkey — TOFU collision
  /// 409 from register_pubkey AND the refreshed JWT still lacks our pubkey
  /// claim → this device's key is owned by a DIFFERENT account (e.g. account
  /// switch on a shared Mac). Actionable: the UI offers a device-identity
  /// reset. Distinct from `.identityClaimMissing` (a transient JWT-hook race
  /// where registration succeeded but the claim hasn't propagated yet).
  case deviceKeyOwnedByAnotherAccount
  /// register_pubkey 409 AND the refreshed JWT carries a DIFFERENT pubkey —
  /// this ACCOUNT is already bound to another device key (second Mac / wiped
  /// keystore). The registry is one-key-per-account with no re-key path yet,
  /// so a local identity reset can NOT recover; surface an honest error
  /// instead of silently admitting a session whose claim mismatches the local
  /// key (every creator-op would 403 with «only the workspace creator…»).
  case accountBoundToDifferentDeviceKey
  case decoding(reason: String)
  case transport(reason: String)
  case unexpected(status: Int)
  /// 410 Gone with a known error code in the JSON body — currently sourced
  /// from `create_join_request` Edge Function (M027 invite redesign):
  /// `invite_not_found` / `invite_deleted` / `invite_expired` /
  /// `invite_exhausted` / `workspace_mismatch`. Callers map the code to
  /// human-readable copy via their own switch (see JoinRequestsReader
  /// `friendlyMessage`).
  case gone(code: String)
  /// S7 Stage 6 fix C-I9 — PostgREST returned 204 but Content-Range header
  /// reports 0 rows affected. Happens when a RLS USING-clause filters out
  /// the row (e.g., non-creator UPDATE silently touches 0 workspaces). The
  /// HTTP status is "successful" but the operation didn't mutate anything;
  /// for destructive ops (rename / soft-delete) this would silently diverge
  /// local from server. Mapped to a user-facing "no permission" message in
  /// WorkspaceReader.userFacingMessage.
  case noRowsAffected

  public static func fromStatus(_ status: Int, body: Data?) -> SupabaseError {
    switch status {
    case 400: return .badRequest
    case 401: return .unauthorized
    case 403: return .forbidden  // I3
    case 404: return .notFound
    case 409: return .conflict
    case 410:
      // M027 invite-redesign Edge Functions return 410 with `{ "error": "<code>" }`
      // body — surface the code to the caller for friendlyMessage mapping.
      // Falls back to .unexpected(410) if body is unparseable / lacks `error`.
      if let code = decodeErrorCode(from: body) {
        return .gone(code: code)
      }
      return .unexpected(status: status)
    case 429: return .rateLimited
    case 500...599: return .serverError
    default: return .unexpected(status: status)
    }
  }

  /// Best-effort `{ "error": "<code>" }` extraction from a JSON error body.
  /// Returns nil if body is missing, not JSON, or lacks a string `error` key.
  private static func decodeErrorCode(from body: Data?) -> String? {
    guard let body, !body.isEmpty else { return nil }
    guard
      let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
      let code = obj["error"] as? String,
      !code.isEmpty
    else { return nil }
    return code
  }

  public static func fromInviteResolve(status: Int, body: Data?) -> SupabaseError {
    if status == 404 { return .inviteNotResolvable }
    return fromStatus(status, body: body)
  }

  public static func fromRegisterPubkey(status: Int, body: Data?) -> SupabaseError {
    if status == 409 { return .pubkeyAlreadyRegistered }
    return fromStatus(status, body: body)
  }

  /// True for transient/infrastructure failures (network down, 5xx, rate-limit)
  /// as opposed to a credential rejection. The auth gate (RootView + Agent)
  /// uses this for offline-grace: a previously-logged-in user with a persisted
  /// session stays in the app and the agent keeps capturing on a transient
  /// blip, instead of being bounced to the login screen / `exit(0)`. A genuine
  /// auth rejection (`.unauthorized` / `.badRequest`) is NOT transient and
  /// still forces re-login.
  public var isTransientNetworkFailure: Bool {
    switch self {
    case .transport, .serverError, .rateLimited: return true
    default: return false
    }
  }
}
