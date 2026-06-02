//
//  GitHubOAuthService.swift
//  Leaf
//
//  Phase 4.3 — @Observable controller for the Connections Settings tab (GitHub).
//  Owns:
//   1) State machine (NotConnected → RequestingDeviceCode → AwaitingAuthorization
//      → ExchangingToken → FetchingViewer → Connected/Error/ReconnectNeeded).
//   2) Device Flow loop (RFC 8628): POST /login/device/code →
//      polling /login/oauth/access_token (authorization_pending / slow_down /
//      expired_token / access_denied / success) → GET /user.
//   3) Persistence: integrations row (provider=.github), workspaceID="github:<login>",
//      workspaceName=<login>.
//   4) Disconnect: deleteIntegration + DistributedNotification (Agent picks up).
//
//  PKCE / LoopbackCallbackListener — NOT needed (Device Flow does not use a
//  loopback redirect; the client_id is public).
//

import Foundation
import SwiftUI
import AppKit
import LeafCore
import os
#if LEAF_PROD
import LeafCorePrivate
#endif

private let oauthLogger = Logger(subsystem: "tech.gundem.leaf.app", category: "github-oauth")

/// Parses GitHub's scope string into a set of tokens. GitHub's OAuth
/// token-exchange JSON response returns scope as **comma-separated**
/// (e.g. `"repo,read:user,read:org"`); the legacy `X-OAuth-Scopes` HTTP
/// header form is space-separated. Split on both — mirrors
/// `GitHubScopesService.parseScopeString` exactly so the app-target
/// derivation in `reload()` / `finishConnect()` stays observationally
/// identical to the LeafCore actor for any input.
///
/// `nil` (no integrations row column) → empty set, treated downstream as
/// "no scopes granted" → all required core surfaced as missing.
private func parseScopeString(_ raw: String?) -> Set<String> {
    guard let raw else { return [] }
    let parts = raw
        .split(whereSeparator: { $0.isWhitespace || $0 == "," })
        .map { String($0) }
        .filter { !$0.isEmpty }
    return Set(parts)
}

@MainActor
@Observable
final class GitHubOAuthService {
    enum ConnectionState: Sendable, Equatable {
        case notConnected
        case requestingDeviceCode
        /// User sees userCode + Open browser / Copy / Cancel buttons.
        /// expiresAt — wall-clock deadline (RFC 8628 device_code TTL ~15 min).
        case awaitingAuthorization(userCode: String, verificationURI: URL, expiresAt: Date)
        case exchangingToken
        case fetchingViewer
        case connected(login: String, connectedAt: Date)
        /// Phase Track-3 D2 — token still valid but core scopes incomplete after
        /// scope-bump release. UI shows banner + red dot + re-authorize CTA
        /// (Tasks 18-21). Connection remains usable for endpoints whose scopes
        /// already granted; warm/cold gated calls degrade gracefully.
        case connectedScopeOutdated(login: String, connectedAt: Date, missing: Set<String>)
        /// refresh_token revoked / expired (GitHubTokenRefresher performed
        /// deleteIntegration + UserDefaults flag + DistributedNotification).
        /// UI shows orange "Reconnect needed". Cleared on a successful
        /// `connect()` or a manual `disconnect()`.
        case reconnectNeeded
        case error(message: String)
    }

    private(set) var state: ConnectionState = .notConnected

    private let databaseURL: URL
    private let databaseConfig: DatabaseConfig
    private let databaseEncryption: EncryptionOptions?
    private let restartTriggerName: String
    private var database: Database?
    /// Phase 5 — non-caching session for OAuth token exchange (bearer/token
    /// responses never hit a disk cache). See `URLSession.leafEphemeral()`.
    private let urlSession: URLSession = .leafEphemeral()
    private var pollingTask: Task<Void, Never>?
    /// Observer token kept around so `deinit` can call `removeObserver`.
    /// Earlier shape discarded the token immediately, leaking the observer
    /// for the process lifetime. `nonisolated(unsafe)` because Swift 6 deinit
    /// runs in a nonisolated context; the token is written once during init
    /// and read once during deinit — no concurrent mutation, no race.
    private nonisolated(unsafe) var integrationChangedObserver: NSObjectProtocol?
    /// Coalescing guard — if a notification storm fires `reload()` calls
    /// back-to-back (e.g., Worker / relay restart cycle), the second-and-
    /// subsequent firings short-circuit instead of hammering `ensureDatabase()`
    /// + `readIntegration` synchronously on @MainActor.
    private var reloadInFlight: Bool = false

    init(
        databaseURL: URL = DatabasePath.defaultURL(),
        databaseConfig: DatabaseConfig = GitHubOAuthService.defaultConfig(),
        databaseEncryption: EncryptionOptions? = GitHubOAuthService.defaultEncryption(),
        restartTriggerName: String = GitHubOAuthEndpoints.integrationChangedNotificationName
    ) {
        self.databaseURL = databaseURL
        self.databaseConfig = databaseConfig
        self.databaseEncryption = databaseEncryption
        self.restartTriggerName = restartTriggerName
        subscribeToIntegrationChangedNotification()
    }

    deinit {
        if let token = integrationChangedObserver {
            DistributedNotificationCenter.default().removeObserver(token)
        }
    }

    // MARK: - Public API

    /// Re-reads the row from the DB → sets `.connected`, `.notConnected`, or
    /// `.reconnectNeeded` if the refresher deleted the row due to invalid_grant.
    func reload() {
        do {
            let db = try ensureDatabase()
            let denied = isRefreshDenialFlagSet()
            if let record = try db.readIntegration(provider: .github) {
                clearRefreshDenialFlag()
                let granted = parseScopeString(record.scope)
                let missing = GitHubScopesService.requiredCore.subtracting(granted)
                if missing.isEmpty {
                    state = .connected(login: record.workspaceName, connectedAt: record.connectedAt)
                } else {
                    state = .connectedScopeOutdated(
                        login: record.workspaceName,
                        connectedAt: record.connectedAt,
                        missing: missing
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

    /// Starts the full Device Flow. Caller — UI button "Connect GitHub".
    /// Convenience overload preserving the existing call shape; delegates to
    /// `connect(scopes:)` with the canonical `GitHubScopesService.requested()`
    /// (D2 scope-bump baseline = required core ∪ optional).
    func connect() async {
        await connect(scopes: GitHubScopesService.requested())
    }

    /// Phase Track-3 D2 — explicit form. Tests + future re-auth flow pass
    /// the exact scope list they want; default convenience overload above
    /// uses `GitHubScopesService.requested()` so existing UI sites compile
    /// unchanged.
    func connect(scopes: [String]) async {
        guard let clientID = readClientID() else {
            state = .error(message: "GITHUB_OAUTH_CLIENT_ID is not configured. See Config/Local.xcconfig.example.")
            return
        }

        // Cancel any in-flight polling task (re-entry on awaitingAuthorization).
        pollingTask?.cancel()
        pollingTask = nil

        state = .requestingDeviceCode

        let scopeParameter = scopes.joined(separator: " ")

        let device: GitHubDeviceCodeResponse
        do {
            device = try await requestDeviceCode(clientID: clientID, scopeParameter: scopeParameter)
        } catch {
            oauthLogger.error("device code request failed: \(String(describing: error), privacy: .public)")
            state = .error(message: "Couldn't start GitHub authorization: \(error.localizedDescription)")
            return
        }

        guard let verificationURL = URL(string: device.verificationURI) else {
            state = .error(message: "GitHub returned a malformed verification URL.")
            return
        }
        let expiresAt = Date().addingTimeInterval(TimeInterval(device.expiresIn))
        state = .awaitingAuthorization(
            userCode: device.userCode,
            verificationURI: verificationURL,
            expiresAt: expiresAt
        )

        // Open the browser right away (verificationURIComplete pre-fills user_code if supported).
        let openURL = device.verificationURIComplete.flatMap(URL.init(string:)) ?? verificationURL
        NSWorkspace.shared.open(openURL)

        // Polling task — cancellation-aware, awaits user authorization.
        pollingTask = Task { [weak self] in
            await self?.pollForToken(
                clientID: clientID,
                deviceCode: device.deviceCode,
                interval: device.interval,
                expiresAt: expiresAt
            )
        }
    }

    /// Cancels in-flight Device Flow polling. UI button "Cancel" in `.awaitingAuthorization`.
    func cancel() {
        pollingTask?.cancel()
        pollingTask = nil
        state = .notConnected
    }

    /// Deletes the row, posts a notification (the Agent collector picks it up and stops polling).
    func disconnect() {
        pollingTask?.cancel()
        pollingTask = nil
        do {
            let db = try ensureDatabase()
            try db.deleteIntegration(provider: .github)
            clearRefreshDenialFlag()
            postRestartNotification()
            state = .notConnected
        } catch {
            oauthLogger.error("disconnect failed: \(String(describing: error), privacy: .public)")
            state = .error(message: "Couldn't disconnect: \(error.localizedDescription)")
        }
    }

    // MARK: - Device Flow internals

    private func requestDeviceCode(clientID: String, scopeParameter: String) async throws -> GitHubDeviceCodeResponse {
        var request = URLRequest(url: GitHubOAuthEndpoints.deviceAuthorize)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formEncoded([
            "client_id": clientID,
            "scope": scopeParameter
        ])

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw makeError("Device code endpoint returned non-HTTP response.")
        }
        guard http.statusCode == 200 else {
            // 404 usually means "Enable Device Flow" toggle is off in OAuth App settings.
            if let errorPayload = try? JSONDecoder().decode(GitHubTokenError.self, from: data) {
                throw makeError(errorPayload.errorDescription ?? errorPayload.error)
            }
            throw makeError("Device code endpoint returned HTTP \(http.statusCode). Verify 'Enable Device Flow' is ON in the GitHub OAuth App.")
        }
        return try JSONDecoder().decode(GitHubDeviceCodeResponse.self, from: data)
    }

    /// Polling loop per RFC 8628 §3.4. Increases interval on `slow_down`,
    /// breaks on success / access_denied / expired_token / cancellation.
    private func pollForToken(
        clientID: String,
        deviceCode: String,
        interval initialInterval: Int,
        expiresAt: Date
    ) async {
        var pollInterval = max(initialInterval, 1)

        while !Task.isCancelled {
            // RFC 8628 §3.5 — sleep BEFORE each poll (except first iteration is acceptable;
            // GitHub recommends to wait `interval` between polls).
            do {
                try await Task.sleep(nanoseconds: UInt64(pollInterval) * 1_000_000_000)
            } catch {
                return  // cancelled during sleep
            }

            if Task.isCancelled { return }
            if Date() >= expiresAt {
                state = .error(message: "User code expired. Click Connect GitHub to try again.")
                return
            }

            let outcome: PollOutcome
            do {
                outcome = try await pollOnce(clientID: clientID, deviceCode: deviceCode)
            } catch {
                oauthLogger.error("poll request failed: \(String(describing: error), privacy: .public)")
                // Network blip — keep polling unless cancelled (next iteration retries).
                continue
            }

            switch outcome {
            case .pending:
                continue
            case .slowDown:
                pollInterval += 5
                continue
            case .accessDenied:
                state = .notConnected
                return
            case .expiredToken:
                state = .error(message: "User code expired. Click Connect GitHub to try again.")
                return
            case .otherError(let msg):
                state = .error(message: msg)
                return
            case .success(let token):
                await finishConnect(token: token)
                return
            }
        }
    }

    private enum PollOutcome {
        case pending
        case slowDown
        case accessDenied
        case expiredToken
        case otherError(String)
        case success(GitHubTokenResponse)
    }

    private func pollOnce(clientID: String, deviceCode: String) async throws -> PollOutcome {
        var request = URLRequest(url: GitHubOAuthEndpoints.token)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formEncoded([
            "client_id": clientID,
            "device_code": deviceCode,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
        ])

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            return .otherError("Token endpoint returned non-HTTP response.")
        }

        // GitHub returns HTTP 200 with either success or error body during device-flow
        // polling — error code lives in JSON, not status.
        if http.statusCode == 200 {
            if let success = try? JSONDecoder().decode(GitHubTokenResponse.self, from: data),
               !success.accessToken.isEmpty {
                return .success(success)
            }
            if let errorPayload = try? JSONDecoder().decode(GitHubTokenError.self, from: data) {
                return mapPollError(errorPayload)
            }
            return .otherError("Token endpoint returned an unrecognized payload.")
        }
        if let errorPayload = try? JSONDecoder().decode(GitHubTokenError.self, from: data) {
            return mapPollError(errorPayload)
        }
        return .otherError("Token endpoint returned HTTP \(http.statusCode).")
    }

    private func mapPollError(_ payload: GitHubTokenError) -> PollOutcome {
        switch payload.error {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown
        case "access_denied": return .accessDenied
        case "expired_token": return .expiredToken
        default: return .otherError(payload.errorDescription ?? payload.error)
        }
    }

    private func finishConnect(token: GitHubTokenResponse) async {
        state = .fetchingViewer
        let viewer: GitHubViewerResponse
        do {
            viewer = try await fetchViewer(accessToken: token.accessToken)
        } catch {
            oauthLogger.error("fetchViewer failed: \(String(describing: error), privacy: .public)")
            state = .error(message: "Couldn't fetch GitHub identity: \(error.localizedDescription)")
            return
        }

        let now = Date()
        let record = IntegrationRecord(
            provider: .github,
            workspaceID: "github:\(viewer.login)",
            workspaceName: viewer.login,
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            expiresAt: token.expiresIn.map { now.addingTimeInterval(TimeInterval($0)) },
            scope: token.scope,
            connectedAt: now,
            updatedAt: now
        )
        do {
            try persistWithRetry(record)
        } catch {
            oauthLogger.error("persist failed: \(String(describing: error), privacy: .public)")
            state = .error(message: "Couldn't save GitHub credentials: \(error.localizedDescription)")
            return
        }
        clearRefreshDenialFlag()
        postRestartNotification()
        let granted = parseScopeString(record.scope)
        let missing = GitHubScopesService.requiredCore.subtracting(granted)
        if missing.isEmpty {
            state = .connected(login: record.workspaceName, connectedAt: record.connectedAt)
        } else {
            state = .connectedScopeOutdated(
                login: record.workspaceName,
                connectedAt: record.connectedAt,
                missing: missing
            )
        }
    }

    private func fetchViewer(accessToken: String) async throws -> GitHubViewerResponse {
        var request = URLRequest(url: GitHubOAuthEndpoints.viewer)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Leaf/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw makeError("Viewer endpoint returned non-HTTP response.")
        }
        guard http.statusCode == 200 else {
            throw makeError("GET /user returned HTTP \(http.statusCode).")
        }
        return try JSONDecoder().decode(GitHubViewerResponse.self, from: data)
    }

    // MARK: - DB / config plumbing

    private func readClientID() -> String? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "LeafGitHubOAuthClientID") as? String,
              !id.isEmpty,
              !id.contains("$(")
        else { return nil }
        return id
    }

    private func persistWithRetry(_ record: IntegrationRecord) throws {
        do {
            let db = try ensureDatabase()
            try db.upsertIntegration(record)
        } catch {
            // Single 100ms retry on SQLite busy (Phase 2.4 R6 pattern, mirrored from Linear).
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
        UserDefaults(suiteName: GitHubOAuthEndpoints.userDefaultsSuite)?
            .bool(forKey: GitHubOAuthEndpoints.refreshDeniedFlagKey) ?? false
    }

    private func clearRefreshDenialFlag() {
        UserDefaults(suiteName: GitHubOAuthEndpoints.userDefaultsSuite)?
            .set(false, forKey: GitHubOAuthEndpoints.refreshDeniedFlagKey)
    }

    private func subscribeToIntegrationChangedNotification() {
        let name = NSNotification.Name(restartTriggerName)
        // Store the returned token so `deinit` can `removeObserver`. The
        // closure also debounces back-to-back firings via `reloadInFlight`
        // — without it, a relay/Worker restart that pumps the notification
        // 10× in a second pumps 10 sync DB reads on @MainActor.
        integrationChangedObserver = DistributedNotificationCenter.default().addObserver(
            forName: name, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.reloadInFlight { return }
                self.reloadInFlight = true
                self.reload()
                self.reloadInFlight = false
            }
        }
    }

    private func makeError(_ message: String) -> NSError {
        NSError(domain: "tech.gundem.leaf.github-oauth", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - Helpers

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
