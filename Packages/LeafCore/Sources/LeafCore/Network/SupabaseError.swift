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
    case forbidden                          // I3 — 403 from PostgREST RLS denial
    case notFound
    case conflict
    case rateLimited
    case serverError
    case authBootstrapFailed(reason: String)
    case identityClaimMissing               // I1 — session has no pubkey claim (Auth Hook race / JWT decode glitch)
    case inviteNotResolvable               // 404 from invite_resolve — token claimed/expired/missing
    case pubkeyAlreadyRegistered           // 409 from register_pubkey — TOFU collision
    case decoding(reason: String)
    case transport(reason: String)
    case unexpected(status: Int)
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
        case 403: return .forbidden        // I3
        case 404: return .notFound
        case 409: return .conflict
        case 429: return .rateLimited
        case 500...599: return .serverError
        default: return .unexpected(status: status)
        }
    }

    public static func fromInviteResolve(status: Int, body: Data?) -> SupabaseError {
        if status == 404 { return .inviteNotResolvable }
        return fromStatus(status, body: body)
    }

    public static func fromRegisterPubkey(status: Int, body: Data?) -> SupabaseError {
        if status == 409 { return .pubkeyAlreadyRegistered }
        return fromStatus(status, body: body)
    }
}
