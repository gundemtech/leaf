//
//  SlackOAuthService.swift
//  Leaf
//
//  Phase 4.4 — @Observable controller for the Connections Settings tab (Slack).
//  Mirrors LinearOAuthService 1:1 in structure (PKCE loopback flow), with
//  Slack-specific deviations:
//   - the authorize URL uses `user_scope` (NOT `scope`) — Slack v2 separates
//     bot/user scopes;
//   - `oauth.v2.access` for the initial code exchange does NOT require a
//     `grant_type` — inferred by Slack from the presence of `code`;
//   - the response shape is separate (SlackOAuthV2Response), the user-token
//     lives in `authed_user.access_token` (xoxp-);
//   - workspaceID = "<team_id>:<user_id>" composite identifier (without the
//     `slack:` prefix — mirrors Linear where workspaceID = just the org UUID);
//   - a separate auth.test is NOT needed — oauth.v2.access already gives team+user.
//
//  Reuses `PKCE.swift` and `LoopbackCallbackListener.swift` from the Linear
//  namespace (same Swift module Leaf — a namespace is just a folder).
//

import Foundation
import SwiftUI
import AppKit
import LeafCore
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
        /// coverage). The UI surfaces a banner + red dot + re-authorize CTA
        /// (Tasks 19-21). The connection stays usable for endpoints with
        /// already-granted scope; warm/cold gated calls degrade gracefully.
        case connectedScopeOutdated(workspaceName: String, connectedAt: Date, missing: Set<String>)
        /// refresh_token revoked / expired (SlackTokenRefresher Phase 4.4 B3
        /// will do deleteIntegration + UserDefaults flag + DistributedNotification).
        /// The UI shows an orange "Reconnect needed". Cleared on a successful
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
    /// Observer token kept so `deinit` can `removeObserver`. Earlier shape
    /// discarded the token and leaked the observer for process lifetime.
    /// `nonisolated(unsafe)` because Swift 6 deinit runs in a nonisolated
    /// context and can't touch MainActor-isolated storage. The token is
    /// written exactly once inside `subscribeToIntegrationChangedNotification()`
    /// (called from MainActor `init`) and read exactly once from deinit —
    /// no concurrent mutation, no race.
    private nonisolated(unsafe) var integrationChangedObserver: NSObjectProtocol?
    /// Coalescing flag so notification storms (Worker / relay restart cycles)
    /// don't pump a sync `reload()` chain through @MainActor.
    private var reloadInFlight: Bool = false
    /// Phase 5 — non-caching session for OAuth token exchange (bearer/token
    /// responses never hit a disk cache). See `URLSession.leafEphemeral()`.
    private let urlSession: URLSession = .leafEphemeral()

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

    deinit {
        if let token = integrationChangedObserver {
            DistributedNotificationCenter.default().removeObserver(token)
        }
    }

    // MARK: - Public API

    /// Re-reads the row from the DB → sets `.connected`,
    /// `.connectedScopeOutdated`, `.notConnected`, or `.reconnectNeeded` if the
    /// refresher (B3) deleted the row due to invalid_grant. Scope-outdated detection
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

    /// Starts the full PKCE flow. Caller — the "Connect Slack" UI button.
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
            authorizeURL = try buildAuthorizeURL(clientID: clientID, challenge: challenge, scopeParameter: scopeParameter)
        } catch {
            state = .error(message: "Failed to build authorize URL: \(error.localizedDescription)")
            return
        }

        // Open the browser before starting the listener — to avoid a race window
        // (see the LinearOAuthService comment, the pattern is identical).
        do {
            state = .waitingForCallback(port: port)
            async let listenerTask = LoopbackCallbackListener.awaitCallback(
                port: port,
                providerLabel: "Slack"
            )
            NSWorkspace.shared.open(authorizeURL)

            let components = try await listenerTask

            // Validate query params.
            let query = Self.queryDict(components)
            if let oauthError = query["error"] {
                let description = query["error_description"] ?? oauthError
                state = .error(message: "Slack declined authorization: \(description)")
                return
            }
            guard let returnedState = query["state"], returnedState == challenge.state else {
                state = .error(message: "OAuth state mismatch — possible interception. Try again.")
                return
            }
            guard let code = query["code"], !code.isEmpty else {
                state = .error(message: "Slack callback missing `code` parameter.")
                return
            }

            // Exchange code → tokens. Slack ok=false → throws .error.
            state = .exchangingToken
            let tokenResponse = try await exchangeCode(
                code: code,
                clientID: clientID,
                verifier: challenge.verifier
            )

            // oauth.v2.access already contains team+user — a separate auth.test is NOT needed.
            state = .fetchingWorkspace
            guard let team = tokenResponse.team,
                  let authedUser = tokenResponse.authedUser,
                  let userAccessToken = authedUser.accessToken,
                  !userAccessToken.isEmpty
            else {
                state = .error(message: "Slack response missing user token (top-level access_token is bot-only).")
                return
            }

            // workspaceID = "<team_id>:<user_id>" composite (without the `slack:` prefix —
            // mirrors Linear where workspaceID = org UUID without the `linear:` prefix; the
            // provider prefix is added only when deriving the sourceID for CollectorOffset).
            let now = Date()
            let workspaceID = "\(team.id):\(authedUser.id)"
            let expiresAt: Date? = {
                guard let seconds = authedUser.expiresIn, seconds > 0 else { return nil }
                return now.addingTimeInterval(TimeInterval(seconds))
            }()
            // Granted scopes (user scopes) live in authed_user.scope. Top-level
            // tokenResponse.scope — bot-token scopes (we don't request them, but
            // we fall back to an empty string).
            let scope = authedUser.scope ?? tokenResponse.scope ?? ""
            let record = IntegrationRecord(
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
            try persistWithRetry(record)
            clearRefreshDenialFlag()
            postRestartNotification()

            // Slack may grant a partial scope set (user declined some).
            // Mirror GitHubOAuthService — surface `.connectedScopeOutdated`
            // if any core scope is missing so the re-auth banner / Sidebar
            // dot / Connections explainer engage immediately (I1 review fix).
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
        } catch let error as LoopbackCallbackError {
            switch error {
            case .timeout:
                state = .error(message: "Authorization timed out. Try again.")
            case .bindFailed(let reason):
                state = .error(message: "Couldn't bind to port \(SlackOAuthEndpoints.loopbackPort): \(reason). Close any conflicting app.")
            case .listenerFailed(let reason):
                state = .error(message: "Local listener failed: \(reason).")
            case .parseFailed:
                state = .error(message: "Couldn't parse callback URL.")
            }
        } catch {
            oauthLogger.error("connect failed: \(String(describing: error), privacy: .public)")
            state = .error(message: error.localizedDescription)
        }
    }

    /// Deletes the row, posts a notification (the Agent collector in B6 picks it up and stops polling).
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
        // Slack v2 separates bot/user scopes:
        //   `scope` — bot-token scopes (we do NOT request them — user-token only is needed)
        //   `user_scope` — user-token scopes (D3: comma-separated from
        //   SlackScopesService.requested() via connect(scopes:) overload)
        // Slack accepts PKCE with `code_challenge_method=S256` for distributed/public apps
        // as of 2026-03-30. `redirect_uri` must be an exact-match with the one in the app config.
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "user_scope", value: scopeParameter),
            URLQueryItem(name: "redirect_uri", value: SlackOAuthEndpoints.redirectURI),
            URLQueryItem(name: "state", value: challenge.state),
            URLQueryItem(name: "code_challenge", value: challenge.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
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
        // NB: Slack `oauth.v2.access` for the initial code exchange does NOT accept
        // `grant_type=authorization_code` — it's inferred from the presence of `code`.
        // For the refresh-flow (B3) `grant_type=refresh_token` is mandatory.
        request.httpBody = Self.formEncoded([
            "client_id": clientID,
            "code": code,
            "redirect_uri": SlackOAuthEndpoints.redirectURI,
            "code_verifier": verifier
        ])

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw makeError("Token endpoint returned non-HTTP response.")
        }
        // Slack returns 200 even for errors — the error info is in the JSON `ok=false` body.
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
            // Single 100ms retry on SQLite busy (Phase 2.4 R6 pattern).
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
        // Stored token → `deinit` removes the observer. `reloadInFlight`
        // coalesces back-to-back firings so a relay/Worker restart storm
        // doesn't pump a chain of sync DB reads on @MainActor.
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
