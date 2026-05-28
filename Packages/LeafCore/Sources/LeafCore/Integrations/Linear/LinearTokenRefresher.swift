//
//  LinearTokenRefresher.swift
//  LeafCore
//
//  Phase 4.1 — refresh helper. В 4.1 dormant: пишем код, runtime
//  не вызывает (collector ещё не существует).
//  Phase 4.2 — LinearCollector в Agent process вызывает `refreshIfNeeded`
//  на каждом polling tick'е. Перенесён из Leaf/ в LeafCore чтобы Agent
//  и main app share'или одну реализацию.
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
    /// Под Phase 4.2 collector передаст shared writer; под Phase 4.1 — main app
    /// share'ит свой `WatchedFoldersService.database`-эквивалент. См. service wiring.
    public let database: Database
    /// Public OAuth client_id из Info.plist (main app) или AgentThresholds (Agent).
    public let clientID: String
    /// Buffer перед `expires_at` в секундах. Refresher срабатывает заранее, чтобы
    /// avoid race с одновременным polling call'ом, который может уйти с уже-просроченным token'ом.
    public let earlyRefreshSeconds: TimeInterval
    /// Non-caching ephemeral session (Phase 5) — token/refresh responses never touch
    /// a disk cache. Injectable for tests (URLProtocol stub).
    public let urlSession: URLSession

    public init(
        database: Database,
        clientID: String,
        earlyRefreshSeconds: TimeInterval = 300,  // 5 min, ничтожный относительно 24h TTL Linear
        urlSession: URLSession = .leafEphemeral()
    ) {
        self.database = database
        self.clientID = clientID
        self.earlyRefreshSeconds = earlyRefreshSeconds
        self.urlSession = urlSession
    }

    /// Refresh access_token если оставшаяся жизнь меньше `earlyRefreshSeconds`.
    /// Возвращает текущий или обновлённый record. Caller использует
    /// `record.accessToken` для следующей API call.
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
            // Long-lived без expiry — Linear не возвращает expires_in только для legacy paths;
            // в 4.1 всегда expires_in=86399. Если nil — допускаем что provider gave long-lived
            // и refresh нечего делать.
            return current
        }
        return try await forceRefresh(current: current, now: now)
    }

    /// Безусловный refresh — вызывается на 401 от API (stale token, может быть
    /// revoked серверной стороной до natural expiry).
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

        // RFC 6749 §5.2 — `invalid_grant` означает refresh_token revoked / expired.
        // Phase 4.2 surface flow: deleteIntegration + UserDefaults flag + DistributedNotification.
        // ConnectionsSettings подписан на notification и читает flag в reload() →
        // показывает orange "Reconnect needed" warning.
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
    /// ConnectionsSettings.reload() читает flag и переключает state в .reconnectNeeded.
    /// Cross-process: обоим бинарям (Agent — где crashes refresh — и main app
    /// которое рендерит UI) виден один UserDefaults suite через kCFPreferencesCurrentApplication.
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
        // application/x-www-form-urlencoded: spaces — `+`, остальное — percent-escape unreserved.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
