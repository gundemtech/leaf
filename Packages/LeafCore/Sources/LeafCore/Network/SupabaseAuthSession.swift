//
//  SupabaseAuthSession.swift
//  LeafCore
//
//  Track 5 / S3 — auth session value type carried by SupabaseClient state machine.
//  In S3 not persisted to disk; fresh signInAnonymously per cold launch.
//  S4 carry-over: persist refresh_token in Keychain for APNs token registration.
//

import Foundation

public struct SupabaseAuthSession: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String
    public let userID: UUID
    public let expiresAt: Date
    /// nil until first refresh after registerPubkey; then carries the pubkey claim injected by Auth Hook.
    public let pubkeyClaim: String?

    public init(accessToken: String,
                refreshToken: String,
                userID: UUID,
                expiresAt: Date,
                pubkeyClaim: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.userID = userID
        self.expiresAt = expiresAt
        self.pubkeyClaim = pubkeyClaim
    }
}
