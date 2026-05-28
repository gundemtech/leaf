//
//  GitHubTokenRefresher.swift
//  LeafCore
//
//  Phase 4.3 — refresh helper для GitHub OAuth Apps (Device Flow).
//  Поддерживает оба режима GitHub OAuth App config:
//  - Long-lived (token expiration OFF): expiresAt=nil, refreshToken=nil → no-op refresh.
//  - Rotating (token expiration ON): expiresAt~8h, refreshToken~6mo → POST /login/oauth/access_token
//    с grant_type=refresh_token; на invalid_grant → surface "Reconnect needed" + delete row.
//
//  GitHubCollector в Agent process вызывает `refreshIfNeeded` на каждом polling tick'е.
//

import Foundation
import os

private let refresherLogger = Logger(subsystem: "tech.gundem.leaf.core", category: "github-token-refresher")

public enum GitHubTokenRefresherError: Error, Equatable, Sendable {
    case notConnected
    case missingRefreshToken
    case refreshDenied(String)
    case network(String)
    case decode(String)
}

public nonisolated struct GitHubTokenRefresher: Sendable {
    public let database: Database
    /// Public OAuth client_id из Info.plist (main app) или AgentThresholds (Agent).
    public let clientID: String
    /// Buffer перед `expires_at` в секундах. Срабатывает заранее, чтобы избежать race
    /// с одновременным polling call'ом, ушедшим с просроченным token'ом. 5 min на 8h TTL ≈ 1%.
    public let earlyRefreshSeconds: TimeInterval
    /// Non-caching ephemeral session (Phase 5) — token/refresh responses never touch
    /// a disk cache. Injectable for tests (URLProtocol stub).
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

    /// Refresh access_token если оставшаяся жизнь меньше `earlyRefreshSeconds`.
    /// Long-lived (expiresAt=nil) → возврат existing record без HTTP call.
    public func refreshIfNeeded(now: Date = Date()) async throws -> IntegrationRecord {
        guard let current = try database.readIntegration(provider: .github) else {
            throw GitHubTokenRefresherError.notConnected
        }
        if let expiresAt = current.expiresAt {
            let remaining = expiresAt.timeIntervalSince(now)
            if remaining > earlyRefreshSeconds {
                return current
            }
        } else {
            // Long-lived OAuth App — token expiration OFF, refresh нечего делать.
            return current
        }
        return try await forceRefresh(current: current, now: now)
    }

    /// Безусловный refresh — вызывается на 401 от API (stale token, может быть
    /// revoked серверной стороной до natural expiry).
    public func forceRefresh(now: Date = Date()) async throws -> IntegrationRecord {
        guard let current = try database.readIntegration(provider: .github) else {
            throw GitHubTokenRefresherError.notConnected
        }
        return try await forceRefresh(current: current, now: now)
    }

    // MARK: - Private

    private func forceRefresh(current: IntegrationRecord, now: Date) async throws -> IntegrationRecord {
        guard let refreshToken = current.refreshToken, !refreshToken.isEmpty else {
            throw GitHubTokenRefresherError.missingRefreshToken
        }

        var request = URLRequest(url: GitHubOAuthEndpoints.token)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formEncoded([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID
        ])

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw GitHubTokenRefresherError.network(String(describing: error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw GitHubTokenRefresherError.network("non-HTTP response")
        }

        if http.statusCode == 200 {
            let decoded: GitHubTokenResponse
            do {
                decoded = try JSONDecoder().decode(GitHubTokenResponse.self, from: data)
            } catch {
                throw GitHubTokenRefresherError.decode(String(describing: error))
            }
            let updated = IntegrationRecord(
                provider: .github,
                workspaceID: current.workspaceID,
                workspaceName: current.workspaceName,
                accessToken: decoded.accessToken,
                refreshToken: decoded.refreshToken ?? current.refreshToken,
                expiresAt: decoded.expiresIn.map { now.addingTimeInterval(TimeInterval($0)) },
                scope: decoded.scope,
                connectedAt: current.connectedAt,
                updatedAt: now
            )
            try database.upsertIntegration(updated)
            return updated
        }

        // RFC 6749 §5.2 — `invalid_grant` означает refresh_token revoked / expired.
        // GitHub возвращает 200 с error body для большинства cases; некоторые edge — 401.
        // Surface flow: deleteIntegration + UserDefaults flag + DistributedNotification →
        // ConnectionsSettings рендерит orange "Reconnect needed" warning.
        let message: String
        if let errorPayload = try? JSONDecoder().decode(GitHubTokenError.self, from: data) {
            message = errorPayload.errorDescription ?? errorPayload.error
            if errorPayload.error == "invalid_grant" {
                refresherLogger.warning("GitHub refresh denied (invalid_grant): \(message, privacy: .public)")
                surfaceRefreshDenied()
                try? database.deleteIntegration(provider: .github)
                throw GitHubTokenRefresherError.refreshDenied(message)
            }
        } else {
            message = "HTTP \(http.statusCode)"
        }
        throw GitHubTokenRefresherError.refreshDenied(message)
    }

    /// Phase 4.3 — write UserDefaults flag + post DistributedNotification.
    /// Cross-process: Agent (где crash'нул refresh) и main app (UI) видят один UserDefaults
    /// suite через kCFPreferencesCurrentApplication. Тот же suite что у Linear,
    /// distinct ключ `github.refreshDenied`.
    private func surfaceRefreshDenied() {
        UserDefaults(suiteName: GitHubOAuthEndpoints.userDefaultsSuite)?
            .set(true, forKey: GitHubOAuthEndpoints.refreshDeniedFlagKey)
        DistributedNotificationCenter.default().post(
            name: NSNotification.Name(GitHubOAuthEndpoints.integrationChangedNotificationName),
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
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
