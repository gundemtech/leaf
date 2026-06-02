//
//  LinearTokenResponse.swift
//  LeafCore
//
//  Phase 4.1 — Codable DTOs for /oauth/token and /graphql viewer responses.
//  Phase 4.2 — moved from Leaf/ to LeafCore (visibility upgraded for cross-binary use).
//  `nonisolated` — the DTOs are decoded by JSONDecoder in the URLSession callback context
//  (inheriting caller isolation), not on @MainActor.
//

import Foundation

/// `POST /oauth/token` success response (RFC 6749 §4.1.4 + §6).
/// Linear returns a refresh_token even for public PKCE clients (verified).
public nonisolated struct LinearTokenResponse: Decodable, Sendable {
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
/// Codable with both `error` and `error_description`; the UI shows the description.
public nonisolated struct LinearTokenError: Decodable, Sendable {
    public let error: String
    public let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

/// `viewer { id organization { id name urlKey } }` response shape.
/// Top-level `data` per GraphQL spec.
public nonisolated struct LinearViewerResponse: Decodable, Sendable {
    public let data: LinearViewerData?
    public let errors: [LinearGraphQLError]?
}

public nonisolated struct LinearViewerData: Decodable, Sendable {
    public let viewer: LinearViewer?
}

public nonisolated struct LinearViewer: Decodable, Sendable {
    public let id: String
    public let organization: LinearOrganization
}

public nonisolated struct LinearOrganization: Decodable, Sendable {
    public let id: String
    public let name: String
    public let urlKey: String
}

public nonisolated struct LinearGraphQLError: Decodable, Sendable {
    public let message: String
}
