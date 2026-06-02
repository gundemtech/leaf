//
//  RotationToken.swift
//  LeafCore
//
//  Phase 5.3.C — Public response value type for `RelayClient.postRotationBlob`.
//  Mirrors the `InviteToken` shape: server-issued URL-safe 32-char identifier
//  + server-side expiry (echoed from request, clamped to relay's MAX_FUTURE_MS).
//

import Foundation

public struct RotationToken: Sendable, Hashable {
    public let value: String
    public let expiresAtMs: Int64
    public init(value: String, expiresAtMs: Int64) {
        self.value = value
        self.expiresAtMs = expiresAtMs
    }
}
