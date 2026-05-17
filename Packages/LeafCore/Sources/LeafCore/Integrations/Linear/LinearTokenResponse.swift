//
//  LinearTokenResponse.swift
//  LeafCore
//
//  Phase 4.1 — Codable DTOs для /oauth/token и /graphql viewer responses.
//  Phase 4.2 — moved из Leaf/ в LeafCore (visibility upgraded для cross-binary).
//  `nonisolated` — DTO читаются JSONDecoder в URLSession callback context
//  (caller isolation inheriting), не на @MainActor.
//

import Foundation

/// `POST /oauth/token` success response (RFC 6749 §4.1.4 + §6).
/// Linear возвращает refresh_token и для public PKCE clients (verified).
nonisolated public struct LinearTokenResponse: Decodable, Sendable {
    public let accessToken: String
    public let tokenType: String
    public let expiresIn: Int?
    public let scope: String
    public let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case scope
        case refreshToken = "refresh_token"
    }
}

/// `POST /oauth/token` error response (RFC 6749 §5.2).
/// Codable с обоими `error` и `error_description`; UI показывает description.
nonisolated public struct LinearTokenError: Decodable, Sendable {
    public let error: String
    public let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

/// `viewer { id organization { id name urlKey } }` response shape.
/// Top-level `data` per GraphQL spec.
nonisolated public struct LinearViewerResponse: Decodable, Sendable {
    public let data: LinearViewerData?
    public let errors: [LinearGraphQLError]?
}

nonisolated public struct LinearViewerData: Decodable, Sendable {
    public let viewer: LinearViewer?
}

nonisolated public struct LinearViewer: Decodable, Sendable {
    public let id: String
    public let organization: LinearOrganization
}

nonisolated public struct LinearOrganization: Decodable, Sendable {
    public let id: String
    public let name: String
    public let urlKey: String
}

nonisolated public struct LinearGraphQLError: Decodable, Sendable {
    public let message: String
}
