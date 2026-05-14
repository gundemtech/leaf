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
    case notFound
    case conflict
    case rateLimited
    case serverError
    case authBootstrapFailed(reason: String)
    case inviteNotResolvable               // 404 from invite_resolve — token claimed/expired/missing
    case pubkeyAlreadyRegistered           // 409 from register_pubkey — TOFU collision
    case decoding(reason: String)
    case transport(reason: String)
    case unexpected(status: Int)

    public static func fromStatus(_ status: Int, body: Data?) -> SupabaseError {
        switch status {
        case 400: return .badRequest
        case 401: return .unauthorized
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
