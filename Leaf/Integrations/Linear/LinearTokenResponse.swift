//
//  LinearTokenResponse.swift
//  Leaf
//
//  Phase 4.1 — Codable DTOs для /oauth/token и /graphql viewer responses.
//  `nonisolated` — DTO читаются JSONDecoder в URLSession callback context
//  (caller isolation inheriting), не на @MainActor.
//

import Foundation

/// `POST /oauth/token` success response (RFC 6749 §4.1.4 + §6).
/// Linear возвращает refresh_token и для public PKCE clients (verified).
nonisolated struct LinearTokenResponse: Decodable, Sendable {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int?
    let scope: String
    let refreshToken: String?

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
nonisolated struct LinearTokenError: Decodable, Sendable {
    let error: String
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

/// `viewer { id organization { id name urlKey } }` response shape.
/// Top-level `data` per GraphQL spec.
nonisolated struct LinearViewerResponse: Decodable, Sendable {
    let data: LinearViewerData?
    let errors: [LinearGraphQLError]?
}

nonisolated struct LinearViewerData: Decodable, Sendable {
    let viewer: LinearViewer?
}

nonisolated struct LinearViewer: Decodable, Sendable {
    let id: String
    let organization: LinearOrganization
}

nonisolated struct LinearOrganization: Decodable, Sendable {
    let id: String
    let name: String
    let urlKey: String
}

nonisolated struct LinearGraphQLError: Decodable, Sendable {
    let message: String
}
