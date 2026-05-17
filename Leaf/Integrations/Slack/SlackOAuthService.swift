//
//  SlackOAuthService.swift
//  Leaf
//
//  Phase 4.4 — @Observable controller для Connections Settings tab (Slack).
//  Mirror'ит LinearOAuthService 1:1 по structure (PKCE loopback flow), с
//  Slack-specific deviations:
//   - authorize URL использует `user_scope` (НЕ `scope`) — Slack v2 разделяет
//     bot/user scopes;
//   - `oauth.v2.access` для initial code exchange НЕ требует `grant_type` —
//     inferred Slack'ом из presence `code`;
//   - response shape отдельный (SlackOAuthV2Response), user-token живёт в
//     `authed_user.access_token` (xoxp-);
//   - workspaceID = "<team_id>:<user_id>" composite identifier (без `slack:`
//     prefix — mirror Linear где workspaceID = просто org UUID);
//   - дополнительный auth.test НЕ нужен — oauth.v2.access уже даёт team+user.
//
//  Reuses `PKCE.swift` и `LoopbackCallbackListener.swift` из Linear namespace
//  (тот же Swift module Leaf — namespace это просто папка).
//

import AppKit
import Foundation
import LeafCore
import SwiftUI
import os

#if LEAF_PROD
import LeafCorePrivate
#endif

private let oauthLogger = Logger(subsystem: "tech.gundem.leaf.app", category: "slack-oauth")

@MainActor
@Observable
final class SlackOAuthService {
    enum ConnectionState: Sendable, Equatable {
        case notConnected
        case authorizing
        case waitingForCallback(port: UInt16)
        case exchangingToken
        case fetchingWorkspace
        case connected(workspaceName: String, connectedAt: Date)
        /// Phase Track-3 D3 — token still valid but Slack scopes incomplete after
        /// scope-bump release (D3 added 9 new optional scopes for warm/cold
        /// coverage). UI surface'ит banner + red dot + re-authorize CTA
        /// (Tasks 19-21). Connection остаётся usable для endpoints с already-granted
        /// scope; warm/cold gated calls degrade gracefully.
        case connectedScopeOutdated(workspaceName: String, connectedAt: Date, missing: Set<String>)
        /// refresh_token revoked / expired (SlackTokenRefresher Phase 4.4 B3
        /// сделает deleteIntegration + UserDefaults flag + DistributedNotification).
        /// UI показывает orange "Reconnect needed". Cleared на successful
        /// `connect()` или manual `disconnect()`.
        case reconnectNeeded
        case error(message: String)
    }

    private(set) var state: ConnectionState = .notConnected

    private let databaseURL: URL
    private let databaseConfig: DatabaseConfig
    private let databaseEncryption: EncryptionOptions?
    private let restartTriggerName: String
    private var database: Database?

    init(
        databaseURL: URL = DatabasePath.defaultURL(),
        databaseConfig: DatabaseConfig = SlackOAuthService.defaultConfig(),
        databaseEncryption: EncryptionOptions? = SlackOAuthService.defaultEncryption(),
        restartTriggerName: String = SlackOAuthEndpoints.integrationChangedNotificationName
    ) {
        self.databaseURL = databaseURL
        self.databaseConfig = databaseConfig
        self.databaseEncryption = databaseEncryption
        self.restartTriggerName = restartTriggerName
        subscribeToIntegrationChangedNotification()
    }

    // MARK: - Public API

    /// Перечитывает row из DB → выставляет `.connected`,
    /// `.connectedScopeOutdated`, `.notConnected`, или `.reconnectNeeded` если
    /// refresher (B3) удалил row из-за invalid_grant. Scope-outdated detection
    /// mirrors GitHubOAuthService.reload — `requiredCore.subtracting(granted)`
    /// drives both this state AND the parallel `SlackScopesReader` observable
    /// consumed by Home banner / Sidebar dot / Connections section (I1 review fix).
    func reload() {
        do {
            let db = try ensureDatabase()
            let denied = isRefreshDenialFlagSet()
            if let record = try db.readIntegration(provider: .slack) {
                clearRefreshDenialFlag()
                let granted = SlackScopesService.parseScopeString(record.scope)
                let missingCore = SlackScopesService.requiredCore.subtracting(granted)
                if missingCore.isEmpty {
                    state = .connected(workspaceName: record.workspaceName, connectedAt: record.connectedAt)
                } else {
                    state = .connectedScopeOutdated(
                        workspaceName: record.workspaceName,
                        connectedAt: record.connectedAt,
                        missing: missingCore
                    )
                }
            } else if denied {
                state = .reconnectNeeded
            } else {
                state = .notConnected
            }
        } catch {
            oauthLogger.error("reload failed: \(String(describing: error), privacy: .public)")
            state = .error(message: "Couldn't read integration state: \(error.localizedDescription)")
        }
    }

    /// Запускает full PKCE flow. Caller — UI button "Connect Slack".
    /// Convenience overload preserving the existing call shape; delegates to
    /// `connect(scopes:)` with the canonical `SlackScopesService.requested()`
    /// (D3 scope-bump baseline = required core ∪ optional).
    func connect() async {
        await connect(scopes: SlackScopesService.requested())
    }

    /// Phase Track-3 D3 — explicit-scope overload for re-auth flows that need
    /// to request a different scope set than the static default. Tests + the
    /// future re-auth ceremony pass the exact scope list they want; the
    /// convenience overload above delegates here with
    /// `SlackScopesService.requested()` so existing UI sites compile unchanged.
    func connect(scopes: [String]) async {
        await connectInternal(scopeParameter: scopes.joined(separator: ","))
    }

    private func connectInternal(scopeParameter: String) async {
        guard let clientID = readClientID() else {
            state = .error(message: "SLACK_OAUTH_CLIENT_ID is not configured. See Config/Production.xcconfig.")
            return
        }

        state = .authorizing
        let challenge = PKCE.makeChallenge()
        let port = SlackOAuthEndpoints.loopbackPort
        let authorizeURL: URL
        do {
            authorizeURL = try buildAuthorizeURL(
                clientID: clientID, challenge: challenge, scopeParameter: scopeParameter)
        } catch {
            state = .error(message: "Failed to build authorize URL: \(error.localizedDescription)")
            return
        }

        // Открываем браузер до старта listener'а — чтобы избежать race window
        // (см. LinearOAuthService комментарий, паттерн идентичный).
        do {
            state = .waitingForCallback(port: port)
            async let listenerTask = LoopbackCallbackListener.awaitCallback(
                port: port,
                providerLabel: "Slack"
            )
            NSWorkspace.shared.open(authorizeURL)

            let components = try await listenerTask
            guard let code = try validateCallback(components: components, challenge: challenge) else {
                return  // state already set by validator
            }
            try await exchangeAndPersist(
                code: code, clientID: clientID, verifier: challenge.verifier)
        } catch let error as LoopbackCallbackError {
            handleListenerError(error)
        } catch {
            oauthLogger.error("connect failed: \(String(describing: error), privacy: .public)")
            state = .error(message: error.localizedDescription)
        }
    }

    /// Parse + validate the OAuth callback URL. Returns the `code` on success;
    /// returns `nil` after setting `state = .error(...)` on validation failures
    /// so the caller can short-circuit. Throws only on listener-level errors
    /// (caller catches `LoopbackCallbackError` separately).
    private func validateCallback(
        components: URLComponents, challenge: PKCE.Challenge
    ) throws -> String? {
        let query = Self.queryDict(components)
        if let oauthError = query["error"] {
            let description = query["error_description"] ?? oauthError
            state = .error(message: "Slack declined authorization: \(description)")
            return nil
        }
        guard let returnedState = query["state"], returnedState == challenge.state else {
            state = .error(message: "OAuth state mismatch — possible interception. Try again.")
            return nil
        }
        guard let code = query["code"], !code.isEmpty else {
            state = .error(message: "Slack callback missing `code` parameter.")
            return nil
        }
        return code
    }

    /// Exchange `code` → tokens via `oauth.v2.access`, persist as
    /// `IntegrationRecord`, and surface granted / missing-scope state.
    /// `oauth.v2.access` уже содержит team+user — отдельный auth.test НЕ нужен.
    private func exchangeAndPersist(code: String, clientID: String, verifier: String) async throws {
        state = .exchangingToken
        let tokenResponse = try await exchangeCode(
            code: code, clientID: clientID, verifier: verifier)

        state = .fetchingWorkspace
        guard let team = tokenResponse.team,
            let authedUser = tokenResponse.authedUser,
            let userAccessToken = authedUser.accessToken,
            !userAccessToken.isEmpty
        else {
            state = .error(message: "Slack response missing user token (top-level access_token is bot-only).")
            return
        }

        let record = buildIntegrationRecord(
            team: team, authedUser: authedUser,
            userAccessToken: userAccessToken, tokenResponse: tokenResponse)
        try persistWithRetry(record)
        clearRefreshDenialFlag()
        postRestartNotification()
        surfaceConnectedState(record: record)
    }

    /// workspaceID = "<team_id>:<user_id>" composite (без `slack:` prefix —
    /// mirror Linear где workspaceID = org UUID без `linear:` prefix; provider
    /// prefix добавляется только при derivation sourceID для CollectorOffset).
    /// Granted scopes (user scopes) live в authed_user.scope. Top-level
    /// tokenResponse.scope — bot-token scopes (мы их не запрашиваем, но
    /// берём fallback на пустую строку).
    private func buildIntegrationRecord(
        team: SlackOAuthV2Response.SlackTeam,
        authedUser: SlackOAuthV2Response.SlackAuthedUser,
        userAccessToken: String,
        tokenResponse: SlackOAuthV2Response
    ) -> IntegrationRecord {
        let now = Date()
        let workspaceID = "\(team.id):\(authedUser.id)"
        let expiresAt: Date? = {
            guard let seconds = authedUser.expiresIn, seconds > 0 else { return nil }
            return now.addingTimeInterval(TimeInterval(seconds))
        }()
        let scope = authedUser.scope ?? tokenResponse.scope ?? ""
        return IntegrationRecord(
            provider: .slack,
            workspaceID: workspaceID,
            workspaceName: team.name,
            accessToken: userAccessToken,
            refreshToken: authedUser.refreshToken,
            expiresAt: expiresAt,
            scope: scope,
            connectedAt: now,
            updatedAt: now
        )
    }

    /// Slack may grant a partial scope set (user declined some). Mirror
    /// `GitHubOAuthService` — surface `.connectedScopeOutdated` if any core
    /// scope is missing so the re-auth banner / Sidebar dot / Connections
    /// explainer engage immediately (I1 review fix).
    private func surfaceConnectedState(record: IntegrationRecord) {
        let granted = SlackScopesService.parseScopeString(record.scope)
        let missingCore = SlackScopesService.requiredCore.subtracting(granted)
        if missingCore.isEmpty {
            state = .connected(workspaceName: record.workspaceName, connectedAt: record.connectedAt)
        } else {
            state = .connectedScopeOutdated(
                workspaceName: record.workspaceName,
                connectedAt: record.connectedAt,
                missing: missingCore
            )
        }
    }

    private func handleListenerError(_ error: LoopbackCallbackError) {
        switch error {
        case .timeout:
            state = .error(message: "Authorization timed out. Try again.")
        case .bindFailed(let reason):
            state = .error(
                message:
                    "Couldn't bind to port \(SlackOAuthEndpoints.loopbackPort): \(reason). Close any conflicting app."
            )
        case .listenerFailed(let reason):
            state = .error(message: "Local listener failed: \(reason).")
        case .parseFailed:
            state = .error(message: "Couldn't parse callback URL.")
        }
    }

    /// Удаляет row, постит notification (Agent collector в B6 подхватит и остановит polling).
    func disconnect() {
        do {
            let db = try ensureDatabase()
            try db.deleteIntegration(provider: .slack)
            clearRefreshDenialFlag()
            postRestartNotification()
            state = .notConnected
        } catch {
            oauthLogger.error("disconnect failed: \(String(describing: error), privacy: .public)")
            state = .error(message: "Couldn't disconnect: \(error.localizedDescription)")
        }
    }

    // MARK: - Internals

    private func readClientID() -> String? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "LeafSlackOAuthClientID") as? String,
            !id.isEmpty,
            !id.contains("$(")
        else { return nil }
        return id
    }

    private func buildAuthorizeURL(clientID: String, challenge: PKCE.Challenge, scopeParameter: String) throws -> URL {
        var components = URLComponents(url: SlackOAuthEndpoints.authorize, resolvingAgainstBaseURL: false)
        // Slack v2 разделяет bot/user scopes:
        //   `scope` — bot-token scopes (мы их НЕ запрашиваем — нужен user-token only)
        //   `user_scope` — user-token scopes (D3: comma-separated from
        //   SlackScopesService.requested() via connect(scopes:) overload)
        // Slack accepts PKCE с `code_challenge_method=S256` для distributed/public apps
        // с 2026-03-30. `redirect_uri` обязателен exact-match с тем что в app config.
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "user_scope", value: scopeParameter),
            URLQueryItem(name: "redirect_uri", value: SlackOAuthEndpoints.redirectURI),
            URLQueryItem(name: "state", value: challenge.state),
            URLQueryItem(name: "code_challenge", value: challenge.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = components?.url else {
            throw makeError("Couldn't build authorize URL")
        }
        return url
    }

    private func exchangeCode(code: String, clientID: String, verifier: String) async throws -> SlackOAuthV2Response {
        var request = URLRequest(url: SlackOAuthEndpoints.token)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // NB: Slack `oauth.v2.access` для initial code exchange НЕ принимает
        // `grant_type=authorization_code` — он inferred из presence `code`.
        // Для refresh-flow (B3) `grant_type=refresh_token` обязателен.
        request.httpBody = Self.formEncoded([
            "client_id": clientID,
            "code": code,
            "redirect_uri": SlackOAuthEndpoints.redirectURI,
            "code_verifier": verifier,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw makeError("Token endpoint returned non-HTTP response.")
        }
        // Slack возвращает 200 даже для ошибок — error info в JSON `ok=false` body.
        guard http.statusCode == 200 else {
            throw makeError("Token endpoint returned HTTP \(http.statusCode).")
        }
        let decoded = try JSONDecoder().decode(SlackOAuthV2Response.self, from: data)
        if !decoded.ok {
            throw makeError("Slack token exchange failed: \(decoded.error ?? "unknown error")")
        }
        return decoded
    }

    private func persistWithRetry(_ record: IntegrationRecord) throws {
        do {
            let db = try ensureDatabase()
            try db.upsertIntegration(record)
        } catch {
            // Single 100ms retry на SQLite busy (Phase 2.4 R6 паттерн).
            Thread.sleep(forTimeInterval: 0.1)
            let db = try ensureDatabase()
            try db.upsertIntegration(record)
        }
    }

    private func ensureDatabase() throws -> Database {
        if let database { return database }
        let db = try Database.openForWrite(at: databaseURL, config: databaseConfig, encryption: databaseEncryption)
        self.database = db
        return db
    }

    private func postRestartNotification() {
        DistributedNotificationCenter.default().post(
            name: NSNotification.Name(restartTriggerName),
            object: nil
        )
    }

    private func isRefreshDenialFlagSet() -> Bool {
        UserDefaults(suiteName: SlackOAuthEndpoints.userDefaultsSuite)?
            .bool(forKey: SlackOAuthEndpoints.refreshDeniedFlagKey) ?? false
    }

    private func clearRefreshDenialFlag() {
        UserDefaults(suiteName: SlackOAuthEndpoints.userDefaultsSuite)?
            .set(false, forKey: SlackOAuthEndpoints.refreshDeniedFlagKey)
    }

    private func subscribeToIntegrationChangedNotification() {
        let name = NSNotification.Name(restartTriggerName)
        DistributedNotificationCenter.default().addObserver(
            forName: name, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    private func makeError(_ message: String) -> NSError {
        NSError(domain: "tech.gundem.leaf.slack-oauth", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - Helpers

    private static func queryDict(_ components: URLComponents) -> [String: String] {
        Dictionary(
            (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private static func formEncoded(_ params: [String: String]) -> Data {
        let pairs = params.map { key, value in
            "\(percentEncode(key))=\(percentEncode(value))"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }

    private static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: - Static defaults

    nonisolated private static func defaultConfig() -> DatabaseConfig {
        #if LEAF_PROD
        return ProdConfigs.database
        #else
        return .weakDefaults
        #endif
    }

    nonisolated private static func defaultEncryption() -> EncryptionOptions? {
        #if LEAF_PROD
        return EncryptionOptions(
            keyProvider: .callback { @Sendable in
                try FileKeyStore.fetchOrCreate()
            },
            preKeyPragmas: ProdConfigs.sqlcipherPragmasPreKey,
            postKeyPragmas: ProdConfigs.sqlcipherPragmasPostKey
        )
        #else
        return nil
        #endif
    }
}
