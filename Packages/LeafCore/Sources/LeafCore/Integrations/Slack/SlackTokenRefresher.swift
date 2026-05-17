//
//  SlackTokenRefresher.swift
//  LeafCore
//
//  Phase 4.4 B3 — refresh helper для Slack OAuth (PKCE / public client).
//  Mirror'ит Linear/GitHub refresher'ы со Slack-specific deviations:
//   - `oauth.v2.access` возвращает 200 даже для ошибок; ok=false → читаем
//     `error` из тела (invalid_grant / token_revoked / etc).
//   - Public client: refresh-запрос идёт без `client_secret` (RFC 6749 §3.2.1
//     для public clients secret не требуется; Slack distributed/public app
//     должен быть зарегистрирован соответственно).
//   - Refresh-response кладёт новый xoxe.xoxp- user-token на TOP LEVEL
//     `access_token` + top-level `refresh_token` + `expires_in`. В
//     отличие от initial code exchange, где user-token в `authed_user`.
//   - Long-lived case: если token rotation выключен на app side, Slack
//     возвращает initial xoxp- без `expires_in` → record.expiresAt=nil →
//     refresher no-op'ит без HTTP-вызова.
//
//  SlackCollector в Agent process будет вызывать `refreshIfNeeded` на
//  каждом polling tick'е (Phase 4.4 B6).
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
    /// Public OAuth client_id из Info.plist (main app) или AgentThresholds (Agent).
    public let clientID: String
    /// Buffer перед `expires_at` в секундах. Срабатывает заранее, чтобы избежать race
    /// с одновременным polling call'ом, ушедшим с просроченным token'ом. 5 min на
    /// 12h Slack TTL ≈ 0.7%.
    public let earlyRefreshSeconds: TimeInterval
    /// URLSession DI — production = `.shared`, тесты подсовывают session с
    /// custom URLProtocol. Кастомность только в URLSessionConfiguration; DTO/
    /// и поведение идентичны.
    public let urlSession: URLSession

    public init(
        database: Database,
        clientID: String,
        earlyRefreshSeconds: TimeInterval = 300,
        urlSession: URLSession = .shared
    ) {
        self.database = database
        self.clientID = clientID
        self.earlyRefreshSeconds = earlyRefreshSeconds
        self.urlSession = urlSession
    }

    /// Refresh access_token если оставшаяся жизнь меньше `earlyRefreshSeconds`.
    /// Long-lived (expiresAt=nil) → возврат existing record без HTTP-вызова —
    /// Slack возвращает `expires_in` только когда token rotation включён на app side.
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
            // Token rotation OFF на app side → long-lived xoxp-, refresh нечего делать.
            return current
        }
        return try await forceRefresh(current: current, now: now)
    }

    /// Безусловный refresh — вызывается на 401-эквивалент (ok=false с invalid_auth)
    /// от API: серверная сторона могла revok'нуть токен до natural expiry.
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
            "refresh_token": refreshToken,
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
            // Slack 99% возвращает 200 с ok=false; не-200 = транспорт/инфра.
            throw SlackTokenRefresherError.network("HTTP \(http.statusCode)")
        }

        let decoded: SlackOAuthV2Response
        do {
            decoded = try JSONDecoder().decode(SlackOAuthV2Response.self, from: data)
        } catch {
            throw SlackTokenRefresherError.decode(String(describing: error))
        }

        if decoded.ok {
            // Refresh-flow кладёт новый user-token на TOP LEVEL — в отличие от
            // initial exchange (там в `authed_user`). Fallback на authedUser —
            // защита от случая когда Slack однажды поменяет shape (paranoid).
            let newAccessToken =
                decoded.accessToken
                ?? decoded.authedUser?.accessToken
            guard let accessToken = newAccessToken, !accessToken.isEmpty else {
                throw SlackTokenRefresherError.decode("Refresh response ok=true but missing access_token")
            }
            let newRefreshToken =
                decoded.refreshToken
                ?? decoded.authedUser?.refreshToken
                ?? current.refreshToken
            let newExpiresAt: Date? = {
                if let seconds = decoded.expiresIn ?? decoded.authedUser?.expiresIn, seconds > 0 {
                    return now.addingTimeInterval(TimeInterval(seconds))
                }
                return nil
            }()
            let newScope =
                decoded.scope
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

        // ok=false — провайдерская ошибка. Категоризируем: terminal (refresh-token
        // мёртв навсегда → Reconnect needed) vs transient (network-ish, retry на
        // следующем tick'е).
        let code = decoded.error ?? "unknown_error"
        let terminalErrors: Set<String> = [
            "invalid_grant",
            "invalid_refresh_token",
            "token_revoked",
            "token_expired",
            "account_inactive",
            "not_authed",
            "no_authed_user",
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
    /// Cross-process: Agent (где crash'нул refresh) и main app (UI) видят один
    /// UserDefaults suite через kCFPreferencesCurrentApplication.
    /// `SlackOAuthService.reload()` читает флаг и переключает state в
    /// `.reconnectNeeded` (B2 уже встроен этот path).
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
        // application/x-www-form-urlencoded: spaces — `+`, остальное — percent-escape unreserved.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
