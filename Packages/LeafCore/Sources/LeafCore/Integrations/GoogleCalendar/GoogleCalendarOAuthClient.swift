//
//  GoogleCalendarOAuthClient.swift
//  LeafCore
//
//  Track-6 P4 — Google Identity Platform OAuth 2.0 token exchange + refresh.
//  Protocol-based HTTP client; concrete URLSession + Codable impl.
//  Spec §7.2 (token exchange) + §7.5 (refresh + invalid_grant handling).
//
//  Token endpoint quirks:
//    • Form-urlencoded body (NOT JSON).
//    • Error envelope at this endpoint is top-level `{"error": "...",
//      "error_description": "..."}` — distinct from CALENDAR API error shape.
//    • `invalid_grant` arrives as HTTP 400; caller transitions UI to
//      `ConnectionState.reconnectNeeded` per spec §7.5.
//    • On refresh Google MAY omit `refresh_token` (only rotates occasionally);
//      caller must preserve the old refresh_token in that case.
//

import Foundation

// MARK: - Protocol

/// HTTP surface for Google Calendar OAuth token exchange + refresh.
/// Protocol-based for mockability via `URLProtocol`-stubbed `URLSession`.
public protocol GoogleCalendarOAuthHTTP: Sendable {
    /// Exchange the authorization code + PKCE verifier for an access + refresh
    /// token pair. First-time exchange after `prompt=consent` MUST return a
    /// refresh_token (spec §7.5); absence throws `.missingResponseField`.
    func exchangeCode(
        code: String,
        codeVerifier: String,
        redirectURI: String,
        clientID: String,
        clientSecret: String
    ) async throws -> GoogleCalendarAPI.TokenResponse

    /// Refresh the access token via the `refresh_token` grant.
    /// `invalid_grant` from Google → throws `.invalidGrant` (caller transitions
    /// to `ConnectionState.reconnectNeeded`). On 200 the response MAY omit
    /// `refresh_token`; caller preserves the old one in that case.
    func refreshToken(
        refreshToken: String,
        clientID: String,
        clientSecret: String
    ) async throws -> GoogleCalendarAPI.TokenResponse
}

// MARK: - Errors

public enum GoogleCalendarOAuthError: Error, Sendable, Equatable {
    /// Refresh token revoked / scope changed / 7-day testing-mode expiry.
    /// Per spec §7.5 caller transitions to ConnectionState.reconnectNeeded.
    case invalidGrant
    case http(statusCode: Int, message: String?)
    /// Underlying `Error` wrapped as `String` for `Equatable` conformance.
    case decoding(String)
    case transport(String)
    case missingResponseField(String)
}

// MARK: - Concrete client

public struct GoogleCalendarOAuthClient: GoogleCalendarOAuthHTTP {
    private let urlSession: URLSession

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    // MARK: exchangeCode

    public func exchangeCode(
        code: String,
        codeVerifier: String,
        redirectURI: String,
        clientID: String,
        clientSecret: String
    ) async throws -> GoogleCalendarAPI.TokenResponse {
        let body = Self.formEncoded([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("client_id", clientID),
            ("client_secret", clientSecret),
            ("code_verifier", codeVerifier),
        ])

        let response = try await post(body: body)

        // Spec §7.5: first exchange after prompt=consent MUST yield refresh_token.
        // Absence is a contract violation we surface explicitly (caller knows
        // upfront vs. discovering it at refresh time).
        guard response.refreshToken != nil else {
            throw GoogleCalendarOAuthError.missingResponseField("refresh_token")
        }
        return response
    }

    // MARK: refreshToken

    public func refreshToken(
        refreshToken: String,
        clientID: String,
        clientSecret: String
    ) async throws -> GoogleCalendarAPI.TokenResponse {
        let body = Self.formEncoded([
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", clientID),
            ("client_secret", clientSecret),
        ])

        // NOTE: On refresh Google often OMITS refresh_token (only rotates
        // occasionally). Returning `.refreshToken == nil` is the documented
        // success path; caller preserves the prior value.
        return try await post(body: body)
    }

    // MARK: - Private — single POST + error classification

    private func post(body: Data) async throws -> GoogleCalendarAPI.TokenResponse {
        var request = URLRequest(url: GoogleCalendarOAuthEndpoints.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw GoogleCalendarOAuthError.transport(String(describing: error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw GoogleCalendarOAuthError.transport("non-HTTP response")
        }

        if (200..<300).contains(http.statusCode) {
            do {
                return try JSONDecoder().decode(GoogleCalendarAPI.TokenResponse.self, from: data)
            } catch {
                throw GoogleCalendarOAuthError.decoding(String(describing: error))
            }
        }

        // Non-2xx: inspect the OAuth-token error envelope (NOT the Calendar
        // API envelope — this endpoint speaks a different shape).
        let errorBody = try? JSONDecoder().decode(TokenErrorBody.self, from: data)
        if errorBody?.error == "invalid_grant" {
            throw GoogleCalendarOAuthError.invalidGrant
        }
        throw GoogleCalendarOAuthError.http(
            statusCode: http.statusCode,
            message: errorBody?.errorDescription ?? errorBody?.error
        )
    }

    // MARK: - Form encoding

    private static func formEncoded(_ params: [(String, String)]) -> Data {
        var components = URLComponents()
        components.queryItems = params.map { URLQueryItem(name: $0.0, value: $0.1) }
        return (components.percentEncodedQuery ?? "").data(using: .utf8) ?? Data()
    }

    // MARK: - Token endpoint error envelope

    /// Google token endpoint error shape: `{"error":"...","error_description":"..."}`.
    /// Distinct from `GoogleCalendarAPI.ErrorEnvelope` which wraps Calendar v3 errors.
    private struct TokenErrorBody: Decodable {
        let error: String?
        let errorDescription: String?

        private enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
        }
    }
}
