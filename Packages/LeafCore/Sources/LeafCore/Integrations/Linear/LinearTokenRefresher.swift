//
//  LinearTokenRefresher.swift
//  LeafCore
//
//  Phase 4.1 — refresh helper. Dormant in 4.1: we write the code, but the
//  runtime never calls it (the collector does not exist yet).
//  Phase 4.2 — LinearCollector in the Agent process calls `refreshIfNeeded`
//  on every polling tick. Moved from Leaf/ to LeafCore so that the Agent
//  and the main app share a single implementation.
//

import Foundation
import os

private let refresherLogger = Logger(subsystem: "tech.gundem.leaf.core", category: "linear-token-refresher")

public enum LinearTokenRefresherError: Error, Equatable, Sendable {
    case notConnected
    case missingRefreshToken
    case refreshDenied(String)
    case network(String)
    case decode(String)
}

public nonisolated struct LinearTokenRefresher: Sendable {
    /// Under Phase 4.2 the collector passes a shared writer; under Phase 4.1 the main app
    /// shares its `WatchedFoldersService.database` equivalent. See service wiring.
    public let database: Database
    /// Public OAuth client_id from Info.plist (main app) or AgentThresholds (Agent).
    public let clientID: String
    /// Buffer before `expires_at`, in seconds. The refresher fires early to
    /// avoid a race with a concurrent polling call that could go out with an already-expired token.
    public let earlyRefreshSeconds: TimeInterval
    /// Non-caching ephemeral session (Phase 5) — token/refresh responses never touch
    /// a disk cache. Injectable for tests (URLProtocol stub).
    public let urlSession: URLSession

    public init(
        database: Database,
        clientID: String,
        earlyRefreshSeconds: TimeInterval = 300,  // 5 min, negligible relative to Linear's 24h TTL
        urlSession: URLSession = .leafEphemeral()
    ) {
        self.database = database
        self.clientID = clientID
        self.earlyRefreshSeconds = earlyRefreshSeconds
        self.urlSession = urlSession
    }

    /// Refresh access_token if the remaining lifetime is less than `earlyRefreshSeconds`.
    /// Returns the current or refreshed record. Caller uses
    /// `record.accessToken` for the next API call.
    public func refreshIfNeeded(now: Date = Date()) async throws -> IntegrationRecord {
        guard let current = try database.readIntegration(provider: .linear) else {
            throw LinearTokenRefresherError.notConnected
        }
        if let expiresAt = current.expiresAt {
            let remaining = expiresAt.timeIntervalSince(now)
            if remaining > earlyRefreshSeconds {
                return current
            }
        } else {
            // Long-lived without expiry — Linear omits expires_in only on legacy paths;
            // in 4.1 it is always expires_in=86399. If nil, we assume the provider gave a long-lived
            // token and there is nothing to refresh.
            return current
        }
        return try await forceRefresh(current: current, now: now)
    }

    /// Unconditional refresh — called on a 401 from the API (stale token, may have been
    /// revoked server-side before natural expiry).
    public func forceRefresh(now: Date = Date()) async throws -> IntegrationRecord {
        guard let current = try database.readIntegration(provider: .linear) else {
            throw LinearTokenRefresherError.notConnected
        }
        return try await forceRefresh(current: current, now: now)
    }

    // MARK: - Private

    private func forceRefresh(current: IntegrationRecord, now: Date) async throws -> IntegrationRecord {
        guard let refreshToken = current.refreshToken, !refreshToken.isEmpty else {
            throw LinearTokenRefresherError.missingRefreshToken
        }

        var request = URLRequest(url: LinearOAuthEndpoints.token)
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
            throw LinearTokenRefresherError.network(String(describing: error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw LinearTokenRefresherError.network("non-HTTP response")
        }

        if http.statusCode == 200 {
            let decoded: LinearTokenResponse
            do {
                decoded = try JSONDecoder().decode(LinearTokenResponse.self, from: data)
            } catch {
                throw LinearTokenRefresherError.decode(String(describing: error))
            }
            let updated = IntegrationRecord(
                provider: .linear,
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

        // RFC 6749 §5.2 — `invalid_grant` means the refresh_token was revoked / expired.
        // Phase 4.2 surface flow: deleteIntegration + UserDefaults flag + DistributedNotification.
        // ConnectionsSettings subscribes to the notification and reads the flag in reload() →
        // shows the orange "Reconnect needed" warning.
        let message: String
        if let errorPayload = try? JSONDecoder().decode(LinearTokenError.self, from: data) {
            message = errorPayload.errorDescription ?? errorPayload.error
            if errorPayload.error == "invalid_grant" {
                refresherLogger.warning("Linear refresh denied (invalid_grant): \(message, privacy: .public)")
                surfaceRefreshDenied()
                try? database.deleteIntegration(provider: .linear)
                throw LinearTokenRefresherError.refreshDenied(message)
            }
        } else {
            message = "HTTP \(http.statusCode)"
        }
        throw LinearTokenRefresherError.refreshDenied(message)
    }

    /// Phase 4.2 — write UserDefaults flag + post DistributedNotification.
    /// ConnectionsSettings.reload() reads the flag and switches state to .reconnectNeeded.
    /// Cross-process: both binaries (the Agent — where the refresh crashes — and the main app
    /// that renders the UI) see one UserDefaults suite via kCFPreferencesCurrentApplication.
    private func surfaceRefreshDenied() {
        UserDefaults(suiteName: LinearOAuthEndpoints.userDefaultsSuite)?
            .set(true, forKey: LinearOAuthEndpoints.refreshDeniedFlagKey)
        DistributedNotificationCenter.default().post(
            name: NSNotification.Name(LinearOAuthEndpoints.integrationChangedNotificationName),
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
