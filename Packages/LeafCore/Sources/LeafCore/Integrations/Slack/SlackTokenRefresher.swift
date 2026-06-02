//
//  SlackTokenRefresher.swift
//  LeafCore
//
//  Phase 4.4 B3 — refresh helper for Slack OAuth (PKCE / public client).
//  Mirrors the Linear/GitHub refreshers with Slack-specific deviations:
//   - `oauth.v2.access` returns 200 even for errors; ok=false → read
//     `error` from the body (invalid_grant / token_revoked / etc).
//   - Public client: the refresh request goes without `client_secret` (RFC 6749 §3.2.1
//     — for public clients no secret is required; a Slack distributed/public app
//     must be registered accordingly).
//   - The refresh response puts the new xoxe.xoxp- user-token at the TOP LEVEL
//     `access_token` + top-level `refresh_token` + `expires_in`. Unlike the
//     initial code exchange, where the user-token is in `authed_user`.
//   - Long-lived case: if token rotation is off on the app side, Slack
//     returns the initial xoxp- without `expires_in` → record.expiresAt=nil →
//     the refresher is a no-op without an HTTP call.
//
//  SlackCollector in the Agent process will call `refreshIfNeeded` on
//  every polling tick (Phase 4.4 B6).
//

import Foundation
import os

private let refresherLogger = Logger(subsystem: "tech.gundem.leaf.core", category: "slack-token-refresher")

public enum SlackTokenRefresherError: Error, Equatable, Sendable {
    case notConnected
    case missingRefreshToken
    case refreshDenied(String)
    case network(String)
    case decode(String)
}

public nonisolated struct SlackTokenRefresher: Sendable {
    public let database: Database
    /// Public OAuth client_id from Info.plist (main app) or AgentThresholds (Agent).
    public let clientID: String
    /// Buffer before `expires_at` in seconds. Fires early to avoid a race
    /// with a concurrent polling call that went out with an expired token. 5 min on
    /// a 12h Slack TTL ≈ 0.7%.
    public let earlyRefreshSeconds: TimeInterval
    /// URLSession DI — production = `.shared`, tests slip in a session with
    /// a custom URLProtocol. The customization is only in URLSessionConfiguration;
    /// the DTOs and behavior are identical.
    public let urlSession: URLSession

    public init(
        database: Database,
        clientID: String,
        earlyRefreshSeconds: TimeInterval = 300,
        urlSession: URLSession = .leafEphemeral()
    ) {
        self.database = database
        self.clientID = clientID
        self.earlyRefreshSeconds = earlyRefreshSeconds
        self.urlSession = urlSession
    }

    /// Refresh access_token if the remaining lifetime is less than `earlyRefreshSeconds`.
    /// Long-lived (expiresAt=nil) → return the existing record without an HTTP call —
    /// Slack returns `expires_in` only when token rotation is enabled on the app side.
    public func refreshIfNeeded(now: Date = Date()) async throws -> IntegrationRecord {
        guard let current = try database.readIntegration(provider: .slack) else {
            throw SlackTokenRefresherError.notConnected
        }
        if let expiresAt = current.expiresAt {
            let remaining = expiresAt.timeIntervalSince(now)
            if remaining > earlyRefreshSeconds {
                return current
            }
        } else {
            // Token rotation OFF on the app side → long-lived xoxp-, nothing to refresh.
            return current
        }
        return try await forceRefresh(current: current, now: now)
    }

    /// Unconditional refresh — called on a 401-equivalent (ok=false with invalid_auth)
    /// from the API: the server side may have revoked the token before its natural expiry.
    public func forceRefresh(now: Date = Date()) async throws -> IntegrationRecord {
        guard let current = try database.readIntegration(provider: .slack) else {
            throw SlackTokenRefresherError.notConnected
        }
        return try await forceRefresh(current: current, now: now)
    }

    // MARK: - Private

    private func forceRefresh(current: IntegrationRecord, now: Date) async throws -> IntegrationRecord {
        guard let refreshToken = current.refreshToken, !refreshToken.isEmpty else {
            throw SlackTokenRefresherError.missingRefreshToken
        }

        var request = URLRequest(url: SlackOAuthEndpoints.token)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formEncoded([
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ])

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw SlackTokenRefresherError.network(String(describing: error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw SlackTokenRefresherError.network("non-HTTP response")
        }
        guard http.statusCode == 200 else {
            // Slack 99% returns 200 with ok=false; non-200 = transport/infra.
            throw SlackTokenRefresherError.network("HTTP \(http.statusCode)")
        }

        let decoded: SlackOAuthV2Response
        do {
            decoded = try JSONDecoder().decode(SlackOAuthV2Response.self, from: data)
        } catch {
            throw SlackTokenRefresherError.decode(String(describing: error))
        }

        if decoded.ok {
            // The refresh flow puts the new user-token at the TOP LEVEL — unlike the
            // initial exchange (where it's in `authed_user`). The fallback to authedUser
            // guards against the case where Slack someday changes the shape (paranoid).
            let newAccessToken = decoded.accessToken
                ?? decoded.authedUser?.accessToken
            guard let accessToken = newAccessToken, !accessToken.isEmpty else {
                throw SlackTokenRefresherError.decode("Refresh response ok=true but missing access_token")
            }
            let newRefreshToken = decoded.refreshToken
                ?? decoded.authedUser?.refreshToken
                ?? current.refreshToken
            let newExpiresAt: Date? = {
                if let seconds = decoded.expiresIn ?? decoded.authedUser?.expiresIn, seconds > 0 {
                    return now.addingTimeInterval(TimeInterval(seconds))
                }
                return nil
            }()
            let newScope = decoded.scope
                ?? decoded.authedUser?.scope
                ?? current.scope

            let updated = IntegrationRecord(
                provider: .slack,
                workspaceID: current.workspaceID,
                workspaceName: current.workspaceName,
                accessToken: accessToken,
                refreshToken: newRefreshToken,
                expiresAt: newExpiresAt,
                scope: newScope,
                connectedAt: current.connectedAt,
                updatedAt: now
            )
            try database.upsertIntegration(updated)
            return updated
        }

        // ok=false — a provider error. Categorize: terminal (refresh-token
        // dead forever → Reconnect needed) vs transient (network-ish, retry on
        // the next tick).
        let code = decoded.error ?? "unknown_error"
        let terminalErrors: Set<String> = [
            "invalid_grant",
            "invalid_refresh_token",
            "token_revoked",
            "token_expired",
            "account_inactive",
            "not_authed",
            "no_authed_user"
        ]
        if terminalErrors.contains(code) {
            refresherLogger.warning("Slack refresh denied (\(code, privacy: .public)): cleaning integration")
            try? database.deleteIntegration(provider: .slack)
            surfaceRefreshDenied()
            throw SlackTokenRefresherError.refreshDenied(code)
        }
        throw SlackTokenRefresherError.network("Slack refresh failed: \(code)")
    }

    /// Phase 4.4 — write UserDefaults flag + post DistributedNotification.
    /// Cross-process: the Agent (where the refresh crashed) and the main app (UI) see one
    /// UserDefaults suite via kCFPreferencesCurrentApplication.
    /// `SlackOAuthService.reload()` reads the flag and switches state to
    /// `.reconnectNeeded` (B2 already wired up this path).
    private func surfaceRefreshDenied() {
        UserDefaults(suiteName: SlackOAuthEndpoints.userDefaultsSuite)?
            .set(true, forKey: SlackOAuthEndpoints.refreshDeniedFlagKey)
        DistributedNotificationCenter.default().post(
            name: NSNotification.Name(SlackOAuthEndpoints.integrationChangedNotificationName),
            object: nil
        )
    }

    private func formEncoded(_ params: [String: String]) -> Data {
        let pairs = params.map { key, value in
            "\(percentEncode(key))=\(percentEncode(value))"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }

    private func percentEncode(_ value: String) -> String {
        // application/x-www-form-urlencoded: spaces — `+`, everything else — percent-escape unreserved.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
