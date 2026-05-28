//
//  LinearOAuthService.swift
//  Leaf
//
//  Phase 4.1 — @Observable controller для Connections Settings tab.
//  Owns:
//   1) State machine (NotConnected → ... → Connected/Error)
//   2) PKCE flow: загрузка authorize URL, loopback listener, token exchange,
//      viewer query, persistence в integrations table.
//   3) Disconnect: delete row + DistributedNotification.
//
//  В 4.1 main app становится 3rd writer над events.sqlite (Agent + WatchedFolders + здесь).
//  busyTimeout=5000ms serialize'ит, 100ms retry once на конфликт — паттерн WatchedFoldersService.
//

import Foundation
import SwiftUI
import AppKit
import LeafCore
import os
#if LEAF_PROD
import LeafCorePrivate
#endif

private let oauthLogger = Logger(subsystem: "tech.gundem.leaf.app", category: "linear-oauth")

@MainActor
@Observable
final class LinearOAuthService {
    enum ConnectionState: Sendable, Equatable {
        case notConnected
        case authorizing
        case waitingForCallback(port: UInt16)
        case exchangingToken
        case fetchingWorkspace
        case connected(workspaceName: String, connectedAt: Date)
        /// Phase 4.2 — refresh_token revoked / expired (LinearTokenRefresher
        /// сделал deleteIntegration + UserDefaults flag + DistributedNotification).
        /// UI показывает orange "Reconnect needed" warning. Cleared на successful
        /// `connect()` или manual `disconnect()`.
        case reconnectNeeded
        case error(message: String)
    }

    /// Public-readable state. UI bind'ится через `@Bindable` / @Environment.
    private(set) var state: ConnectionState = .notConnected

    private let databaseURL: URL
    private let databaseConfig: DatabaseConfig
    private let databaseEncryption: EncryptionOptions?
    private let restartTriggerName: String
    private var database: Database?
    /// Observer token kept so `deinit` can `removeObserver`. Earlier shape
    /// discarded the token and leaked the observer for process lifetime.
    /// `nonisolated(unsafe)` because Swift 6 deinit runs nonisolated and
    /// can't touch MainActor-isolated storage; token is written once
    /// during MainActor init and read once during deinit.
    private nonisolated(unsafe) var integrationChangedObserver: NSObjectProtocol?
    /// Coalescing flag so notification storms (Worker / relay restart cycles)
    /// don't pump a sync `reload()` chain through @MainActor.
    private var reloadInFlight: Bool = false
    /// Phase 5 — non-caching session for OAuth token exchange (bearer/token
    /// responses never hit a disk cache). See `URLSession.leafEphemeral()`.
    private let urlSession: URLSession = .leafEphemeral()

    init(
        databaseURL: URL = DatabasePath.defaultURL(),
        databaseConfig: DatabaseConfig = LinearOAuthService.defaultConfig(),
        databaseEncryption: EncryptionOptions? = LinearOAuthService.defaultEncryption(),
        restartTriggerName: String = LinearOAuthEndpoints.integrationChangedNotificationName
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

    /// Перечитывает row из DB → выставляет `.connected`, `.notConnected`,
    /// или (Phase 4.2) `.reconnectNeeded` если refresher удалил row из-за
    /// invalid_grant. Settings view вызывает `.onAppear` чтобы реабилитировать
    /// state после cold launch и после disconnect / reconnect cycles.
    func reload() {
        do {
            let db = try ensureDatabase()
            let denied = isRefreshDenialFlagSet()
            if let record = try db.readIntegration(provider: .linear) {
                // Successful row exists — clear stale flag (e.g. юзер вернулся
                // после reconnect, или manual reconnect через connect()).
                clearRefreshDenialFlag()
                state = .connected(workspaceName: record.workspaceName, connectedAt: record.connectedAt)
            } else if denied {
                // Row deleted by refresher's invalid_grant path — UI показывает
                // orange warning "Reconnect needed".
                state = .reconnectNeeded
            } else {
                state = .notConnected
            }
        } catch {
            oauthLogger.error("reload failed: \(String(describing: error), privacy: .public)")
            state = .error(message: "Couldn't read integration state: \(error.localizedDescription)")
        }
    }

    /// Запускает full OAuth flow. Caller — UI button "Connect".
    /// Вся последовательность runs в Task — в state machine видно где сейчас.
    func connect() async {
        guard let clientID = readClientID() else {
            state = .error(message: "LINEAR_OAUTH_CLIENT_ID is not configured. See Config/Local.xcconfig.example.")
            return
        }

        state = .authorizing
        let challenge = PKCE.makeChallenge()
        let port = LinearOAuthEndpoints.redirectPort
        let authorizeURL: URL
        do {
            authorizeURL = try buildAuthorizeURL(clientID: clientID, challenge: challenge)
        } catch {
            state = .error(message: "Failed to build authorize URL: \(error.localizedDescription)")
            return
        }

        // Открываем браузер до старта listener'а — иначе race: listener bind может занять
        // несколько ms, а browser быстрее к этому моменту переходит. Listener стартанёт
        // up to ~10ms after — Linear redirect занимает >100ms, так что точно успеет.
        // (Если listener bind упал — тоже тогда видно ДО browser open'а.)
        do {
            state = .waitingForCallback(port: port)
            async let listenerTask = LoopbackCallbackListener.awaitCallback(port: port)
            NSWorkspace.shared.open(authorizeURL)

            let components = try await listenerTask

            // Validate query params.
            let query = Self.queryDict(components)
            if let oauthError = query["error"] {
                let description = query["error_description"] ?? oauthError
                state = .error(message: "Linear declined authorization: \(description)")
                return
            }
            guard let returnedState = query["state"], returnedState == challenge.state else {
                state = .error(message: "OAuth state mismatch — possible interception. Try again.")
                return
            }
            guard let code = query["code"], !code.isEmpty else {
                state = .error(message: "Linear callback missing `code` parameter.")
                return
            }

            // Exchange code → tokens.
            state = .exchangingToken
            let tokenResponse = try await exchangeCode(
                code: code,
                clientID: clientID,
                verifier: challenge.verifier
            )

            // Fetch viewer.
            state = .fetchingWorkspace
            let viewer = try await fetchViewer(accessToken: tokenResponse.accessToken)

            // Persist.
            let now = Date()
            let record = IntegrationRecord(
                provider: .linear,
                workspaceID: viewer.organization.id,
                workspaceName: viewer.organization.name,
                accessToken: tokenResponse.accessToken,
                refreshToken: tokenResponse.refreshToken,
                expiresAt: tokenResponse.expiresIn.map { now.addingTimeInterval(TimeInterval($0)) },
                scope: tokenResponse.scope,
                connectedAt: now,
                updatedAt: now
            )
            try persistWithRetry(record)
            // Phase 4.2 — successful reconnect clears stale "reconnect needed" flag.
            clearRefreshDenialFlag()
            postRestartNotification()

            state = .connected(workspaceName: record.workspaceName, connectedAt: record.connectedAt)
        } catch let error as LoopbackCallbackError {
            switch error {
            case .timeout:
                state = .error(message: "Authorization timed out. Try again.")
            case .bindFailed(let reason):
                state = .error(message: "Couldn't bind to port \(LinearOAuthEndpoints.redirectPort): \(reason). Close any conflicting app.")
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

    /// Удаляет row, постит notification (в 4.2 collector подхватит и остановит polling).
    func disconnect() {
        do {
            let db = try ensureDatabase()
            try db.deleteIntegration(provider: .linear)
            postRestartNotification()
            state = .notConnected
        } catch {
            oauthLogger.error("disconnect failed: \(String(describing: error), privacy: .public)")
            state = .error(message: "Couldn't disconnect: \(error.localizedDescription)")
        }
    }

    // MARK: - Internals

    private func readClientID() -> String? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "LeafLinearOAuthClientID") as? String,
              !id.isEmpty,
              !id.contains("$(")
        else { return nil }
        return id
    }

    private func buildAuthorizeURL(clientID: String, challenge: PKCE.Challenge) throws -> URL {
        var components = URLComponents(url: LinearOAuthEndpoints.authorize, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: LinearOAuthEndpoints.redirectURI),
            URLQueryItem(name: "scope", value: LinearOAuthEndpoints.scope),
            URLQueryItem(name: "state", value: challenge.state),
            URLQueryItem(name: "code_challenge", value: challenge.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "actor", value: LinearOAuthEndpoints.actor),
            URLQueryItem(name: "prompt", value: "consent")
        ]
        guard let url = components?.url else {
            throw NSError(domain: "tech.gundem.leaf.linear-oauth", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't build authorize URL"
            ])
        }
        return url
    }

    private func exchangeCode(code: String, clientID: String, verifier: String) async throws -> LinearTokenResponse {
        var request = URLRequest(url: LinearOAuthEndpoints.token)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formEncoded([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": LinearOAuthEndpoints.redirectURI,
            "client_id": clientID,
            "code_verifier": verifier
        ])

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw makeError("Token endpoint returned non-HTTP response.")
        }
        guard http.statusCode == 200 else {
            if let errorPayload = try? JSONDecoder().decode(LinearTokenError.self, from: data) {
                throw makeError(errorPayload.errorDescription ?? errorPayload.error)
            }
            throw makeError("Token endpoint returned HTTP \(http.statusCode).")
        }
        return try JSONDecoder().decode(LinearTokenResponse.self, from: data)
    }

    private func fetchViewer(accessToken: String) async throws -> LinearViewer {
        var request = URLRequest(url: LinearOAuthEndpoints.graphql)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = ["query": LinearOAuthEndpoints.viewerQuery]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw makeError("Viewer endpoint returned non-HTTP response.")
        }
        guard http.statusCode == 200 else {
            throw makeError("Viewer endpoint returned HTTP \(http.statusCode).")
        }
        let decoded = try JSONDecoder().decode(LinearViewerResponse.self, from: data)
        if let errors = decoded.errors, !errors.isEmpty {
            throw makeError(errors.map(\.message).joined(separator: "; "))
        }
        guard let viewer = decoded.data?.viewer else {
            throw makeError("Viewer response missing `data.viewer`.")
        }
        return viewer
    }

    private func persistWithRetry(_ record: IntegrationRecord) throws {
        do {
            let db = try ensureDatabase()
            try db.upsertIntegration(record)
        } catch {
            // Phase 2.4 R6 паттерн — single 100ms retry на SQLite busy.
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

    // MARK: - Phase 4.2 refreshDenied surface

    /// Cross-process flag set by LinearTokenRefresher на invalid_grant. Mirror
    /// constant defined в LeafCore (LinearOAuthEndpoints.userDefaultsSuite/Key).
    private func isRefreshDenialFlagSet() -> Bool {
        UserDefaults(suiteName: LinearOAuthEndpoints.userDefaultsSuite)?
            .bool(forKey: LinearOAuthEndpoints.refreshDeniedFlagKey) ?? false
    }

    private func clearRefreshDenialFlag() {
        UserDefaults(suiteName: LinearOAuthEndpoints.userDefaultsSuite)?
            .set(false, forKey: LinearOAuthEndpoints.refreshDeniedFlagKey)
    }

    /// Subscribe на DistributedNotification от Refresher (cross-process) и
    /// own connect/disconnect (intra-process). Когда flag flip'ится → reload()
    /// видит новое state. Без observer'а юзер увидел бы stale state до next
    /// `.onAppear` Settings view. Token хранится — `deinit` removeObserver'ит.
    /// `reloadInFlight` коалесит back-to-back firings (e.g., relay restart
    /// pump'ит notification N раз в секунду).
    private func subscribeToIntegrationChangedNotification() {
        let name = NSNotification.Name(restartTriggerName)
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
        NSError(domain: "tech.gundem.leaf.linear-oauth", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
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
