//
//  GoogleCalendarOAuthService.swift
//  Leaf
//
//  Track-6 P4 — @Observable controller for Connections Settings (Google
//  Calendar). Mirrors `LinearOAuthService` / `SlackOAuthService` 1:1 with a
//  few Google-specific deviations:
//   - ephemeral loopback port (NWListener kernel-assigned, NOT a fixed
//     constant — Google has no fixed-port relay constraint and ephemeral is
//     more robust under concurrent flows). The `redirect_uri` query param is
//     stamped with the real port surfaced by the listener's `.ready` state.
//   - confidential client (`client_secret` shipped, plumbed via Info.plist
//     from .env at build time — moat per CLAUDE.md). Google rejects
//     unauthenticated token exchanges from native apps even with PKCE.
//   - identity captured via `calendarList.get(primary)` — `entry.id` is the
//     authenticated user's primary-calendar address (typically their email)
//     and serves as the stable workspace identifier (plaintext per spec §7.3).
//   - `reload()` has no UserDefaults-flag branch: `GoogleCalendarTokenRefresher`
//     surfaces `invalid_grant` as a typed outcome rather than a cross-process
//     flag. The collector pipeline (Tasks 13+) drives the
//     `markReconnectNeeded()` transition explicitly.
//
//  Reuses `PKCE.swift` and `LoopbackCallbackListener.swift` from the Linear
//  namespace — same Swift module (`Leaf`).
//

import AppKit
import Foundation
import LeafCore
import Observation
import os

#if LEAF_PROD
import LeafCorePrivate
#endif

private let oauthLogger = Logger(subsystem: "tech.gundem.leaf.app", category: "google-calendar-oauth")

/// NSLock-guarded box used to hand off the kernel-assigned ephemeral port
/// from the listener's stateUpdateHandler (called on an internal NW queue)
/// back to the MainActor `connect()` flow. Trivial atomic-style getter +
/// setter — race-free under Swift 6 strict concurrency.
private final class AssignedPortBox: @unchecked Sendable {
    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var port: UInt16?

    nonisolated func set(_ p: UInt16) {
        lock.lock()
        defer { lock.unlock() }
        port = p
    }

    nonisolated func value() -> UInt16? {
        lock.lock()
        defer { lock.unlock() }
        return port
    }
}

@MainActor
@Observable
final class GoogleCalendarOAuthService {
    enum ConnectionState: Sendable, Equatable {
        case notConnected
        case authorizing
        case waitingForCallback(port: UInt16)
        case exchangingToken
        case fetchingWorkspace
        case connected(workspaceName: String, connectedAt: Date)
        /// `GoogleCalendarTokenRefresher` returned `.invalidGrant` (refresh
        /// token revoked / 7-day testing-mode expiry / scope changed). UI
        /// surfaces an orange "Reconnect needed" banner; cleared on a
        /// successful subsequent `connect()` or manual `disconnect()`.
        case reconnectNeeded
        case error(message: String)
    }

    /// Public-readable state for UI binding.
    private(set) var state: ConnectionState = .notConnected

    // MARK: - Dependencies (DI for tests)

    private let http: GoogleCalendarOAuthHTTP
    private let api: GoogleCalendarAPIClient
    private let databaseURL: URL
    private let databaseConfig: DatabaseConfig
    private let databaseEncryption: EncryptionOptions?
    private let restartTriggerName: String
    private let openURL: @MainActor (URL) -> Void
    private var database: Database?

    init(
        http: GoogleCalendarOAuthHTTP = GoogleCalendarOAuthClient(),
        api: GoogleCalendarAPIClient = ProdGoogleCalendarAPIClient(),
        databaseURL: URL = DatabasePath.defaultURL(),
        databaseConfig: DatabaseConfig = GoogleCalendarOAuthService.defaultConfig(),
        databaseEncryption: EncryptionOptions? = GoogleCalendarOAuthService.defaultEncryption(),
        restartTriggerName: String = GoogleCalendarOAuthEndpoints.integrationChangedNotificationName,
        openURL: @escaping @MainActor (URL) -> Void = { url in NSWorkspace.shared.open(url) }
    ) {
        self.http = http
        self.api = api
        self.databaseURL = databaseURL
        self.databaseConfig = databaseConfig
        self.databaseEncryption = databaseEncryption
        self.restartTriggerName = restartTriggerName
        self.openURL = openURL
        subscribeToIntegrationChangedNotification()
    }

    // MARK: - Public API

    /// Re-read the DB row → outwardly emit `.connected` / `.notConnected`.
    /// Settings view calls this on `.onAppear` to rehydrate after cold launch
    /// or after disconnect / reconnect cycles. Distinct from Linear/Slack: no
    /// UserDefaults refresh-denial flag — `.reconnectNeeded` is set explicitly
    /// via `markReconnectNeeded()` from the refresher or collector tick.
    func reload() {
        do {
            let db = try ensureDatabase()
            if let record = try db.readIntegration(provider: .googleCalendar) {
                state = .connected(
                    workspaceName: record.workspaceName,
                    connectedAt: record.connectedAt
                )
            } else {
                // Preserve a sticky `.reconnectNeeded` across reload — the
                // row is gone but the prior tick already informed UI. If we
                // had been in any other state, drop to `.notConnected`.
                if case .reconnectNeeded = state {
                    // keep
                } else {
                    state = .notConnected
                }
            }
        } catch {
            oauthLogger.error("reload failed: \(String(describing: error), privacy: .public)")
            state = .error(message: "Couldn't read integration state: \(error.localizedDescription)")
        }
    }

    /// Drive the full PKCE flow. Caller — UI "Connect Google Calendar" button.
    func connect() async {
        guard let creds = readOAuthCreds() else { return }  // state set inside

        state = .authorizing
        let challenge = PKCE.makeChallenge()

        // Bind the loopback listener on an ephemeral port FIRST so that we
        // know the actual port number to embed into `redirect_uri` before
        // opening the browser. The listener fires `onPortAssigned` from its
        // `.ready` state callback exactly once; an `AssignedPortBox` shared
        // with the closure stores the result via NSLock for Sendable safety.
        let portBox = AssignedPortBox()
        async let listenerTask = LoopbackCallbackListener.awaitCallback(
            port: 0,
            providerLabel: "Google Calendar",
            onPortAssigned: { @Sendable [portBox] p in portBox.set(p) }
        )

        guard let assignedPort = await waitForAssignedPort(portBox: portBox) else {
            state = .error(message: "Listener did not surface an ephemeral port within 1s.")
            _ = try? await listenerTask
            return
        }
        state = .waitingForCallback(port: assignedPort)

        let redirectURI =
            "http://\(GoogleCalendarOAuthEndpoints.redirectHost):\(assignedPort)\(GoogleCalendarOAuthEndpoints.redirectPath)"
        let authorizeURL = GoogleCalendarOAuthEndpoints.authorizeURL(
            clientID: creds.clientID,
            challenge: challenge.challenge,
            state: challenge.state,
            port: assignedPort
        )

        do {
            // Open the browser AFTER the listener is confirmed bound — no
            // race window for the redirect to land on a dead socket.
            openURL(authorizeURL)
            let components = try await listenerTask
            guard let code = validateCallback(components: components, challenge: challenge) else {
                return
            }
            await exchangeAndPersist(
                code: code, verifier: challenge.verifier, redirectURI: redirectURI, creds: creds)
        } catch let error as LoopbackCallbackError {
            handleListenerError(error)
        } catch {
            oauthLogger.error("connect failed: \(String(describing: error), privacy: .public)")
            state = .error(message: error.localizedDescription)
        }
    }

    private struct OAuthCreds {
        let clientID: String
        let clientSecret: String
    }

    /// Read clientID + clientSecret from Info.plist. Sets `.error` state and
    /// returns nil if either is missing.
    private func readOAuthCreds() -> OAuthCreds? {
        guard let clientID = readBundleString(GoogleCalendarOAuthEndpoints.infoPlistClientIDKey) else {
            state = .error(
                message:
                    "\(GoogleCalendarOAuthEndpoints.infoPlistClientIDKey) is not configured. See Config/Local.xcconfig.example."
            )
            return nil
        }
        guard let clientSecret = readBundleString(GoogleCalendarOAuthEndpoints.infoPlistClientSecretKey) else {
            state = .error(
                message:
                    "\(GoogleCalendarOAuthEndpoints.infoPlistClientSecretKey) is not configured. See Config/Local.xcconfig.example."
            )
            return nil
        }
        return OAuthCreds(clientID: clientID, clientSecret: clientSecret)
    }

    /// Spin-wait briefly (≤ ~1s) for the listener to surface its port.
    /// NWListener typically reaches `.ready` within a few ms on loopback;
    /// 100 × 10ms is a generous ceiling that errs on the safe side.
    private func waitForAssignedPort(portBox: AssignedPortBox) async -> UInt16? {
        for _ in 0..<100 {
            if let p = portBox.value() {
                return p
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    /// Parse + validate the OAuth callback URL. Returns the `code` on success;
    /// returns nil after setting `.error` state on validation failures so the
    /// caller can short-circuit.
    private func validateCallback(
        components: URLComponents, challenge: PKCE.Challenge
    ) -> String? {
        let query = Self.queryDict(components)
        if let oauthError = query["error"] {
            let description = query["error_description"] ?? oauthError
            state = .error(message: "Google declined authorization: \(description)")
            return nil
        }
        guard let returnedState = query["state"], returnedState == challenge.state else {
            state = .error(message: "OAuth state mismatch — possible interception. Try again.")
            return nil
        }
        guard let code = query["code"], !code.isEmpty else {
            state = .error(message: "Google callback missing `code` parameter.")
            return nil
        }
        return code
    }

    /// Exchange code → tokens, capture primary calendar identity, persist
    /// `IntegrationRecord`, post restart notification, surface `.connected`.
    /// Sets `.error` state and returns silently on any sub-step failure.
    private func exchangeAndPersist(
        code: String, verifier: String, redirectURI: String, creds: OAuthCreds
    ) async {
        state = .exchangingToken
        let tokenResponse: GoogleCalendarAPI.TokenResponse
        do {
            tokenResponse = try await http.exchangeCode(
                code: code,
                codeVerifier: verifier,
                redirectURI: redirectURI,
                clientID: creds.clientID,
                clientSecret: creds.clientSecret
            )
        } catch let error as GoogleCalendarOAuthError {
            state = .error(message: Self.describe(error))
            return
        } catch {
            state = .error(message: error.localizedDescription)
            return
        }

        // Guard contractually-enforced by the client (`missingResponseField`
        // throws above) — double-check here so the persistence step can pass
        // a non-optional refresh_token down.
        guard let refreshToken = tokenResponse.refreshToken else {
            state = .error(
                message: "Google did not return a refresh_token. Sign out of any prior Leaf grant and retry.")
            return
        }

        // Identity capture via calendarList.get(primary). `entry.id` is the
        // authenticated user's primary calendar address (typically their
        // email) — stable across token rotations, plaintext per spec §7.3.
        state = .fetchingWorkspace
        let primaryEntry: GoogleCalendarAPI.CalendarListEntry
        do {
            primaryEntry = try await api.calendarListGetPrimary(accessToken: tokenResponse.accessToken)
        } catch let error as GoogleCalendarAPIError {
            state = .error(message: "Couldn't read primary calendar: \(Self.describe(error))")
            return
        } catch {
            state = .error(message: "Couldn't read primary calendar: \(error.localizedDescription)")
            return
        }

        // Workspace name: prefer user-set override, fall back to system
        // summary, finally fall back to the calendar id (the email).
        let workspaceName =
            primaryEntry.summaryOverride
            ?? primaryEntry.summary
            ?? primaryEntry.id

        let now = Date()
        let record = IntegrationRecord(
            provider: .googleCalendar,
            workspaceID: primaryEntry.id,
            workspaceName: workspaceName,
            accessToken: tokenResponse.accessToken,
            refreshToken: refreshToken,
            expiresAt: now.addingTimeInterval(TimeInterval(tokenResponse.expiresIn)),
            scope: tokenResponse.scope ?? GoogleCalendarOAuthEndpoints.scope,
            connectedAt: now,
            updatedAt: now
        )
        do {
            try persistWithRetry(record)
        } catch {
            state = .error(message: "Couldn't persist integration: \(error.localizedDescription)")
            return
        }
        postRestartNotification()
        state = .connected(workspaceName: record.workspaceName, connectedAt: record.connectedAt)
    }

    private func handleListenerError(_ error: LoopbackCallbackError) {
        switch error {
        case .timeout:
            state = .error(message: "Authorization timed out. Try again.")
        case .bindFailed(let reason):
            state = .error(message: "Couldn't bind loopback listener: \(reason). Close any conflicting app.")
        case .listenerFailed(let reason):
            state = .error(message: "Local listener failed: \(reason).")
        case .parseFailed:
            state = .error(message: "Couldn't parse callback URL.")
        }
    }

    /// Wipe the `integrations` row + all `provider_snapshots` rows for this
    /// provider so a subsequent reconnect starts from clean bootstrap (no
    /// stale syncToken / `known_calendars` snapshot). Idempotent.
    func disconnect() {
        do {
            let db = try ensureDatabase()
            try db.deleteIntegration(provider: .googleCalendar)
            try db.deleteProviderSnapshots(provider: IntegrationProvider.googleCalendar.rawValue)
            postRestartNotification()
            state = .notConnected
        } catch {
            oauthLogger.error("disconnect failed: \(String(describing: error), privacy: .public)")
            state = .error(message: "Couldn't disconnect: \(error.localizedDescription)")
        }
    }

    /// Called by the collector / refresher when `invalid_grant` is seen and
    /// the integration row has already been dropped. UI surfaces a "Reconnect
    /// needed" banner; clears on the next successful `connect()` /
    /// `disconnect()`.
    func markReconnectNeeded() {
        state = .reconnectNeeded
    }

    // MARK: - Internals

    private func readBundleString(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
            !value.isEmpty,
            // Reject unsubstituted xcconfig placeholders ("$(LEAF_GCAL_…)").
            !value.contains("$(")
        else { return nil }
        return value
    }

    private func persistWithRetry(_ record: IntegrationRecord) throws {
        do {
            let db = try ensureDatabase()
            try db.upsertIntegration(record)
        } catch {
            // Match Linear/Slack: single 100ms retry on SQLite busy contention
            // (Agent writer may briefly hold the lock during a tick).
            Thread.sleep(forTimeInterval: 0.1)
            let db = try ensureDatabase()
            try db.upsertIntegration(record)
        }
    }

    private func ensureDatabase() throws -> Database {
        if let database { return database }
        let db = try Database.openForWrite(
            at: databaseURL,
            config: databaseConfig,
            encryption: databaseEncryption
        )
        self.database = db
        return db
    }

    private func postRestartNotification() {
        DistributedNotificationCenter.default().post(
            name: NSNotification.Name(restartTriggerName),
            object: nil
        )
    }

    /// Subscribe to the same cross-process notification we post — Refresher /
    /// collector → `markReconnectNeeded()` followed by a notification gives
    /// the UI a chance to re-read DB state without explicit `.onAppear`.
    private func subscribeToIntegrationChangedNotification() {
        let name = NSNotification.Name(restartTriggerName)
        DistributedNotificationCenter.default().addObserver(
            forName: name, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
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

    private static func describe(_ error: GoogleCalendarOAuthError) -> String {
        switch error {
        case .invalidGrant:
            return "Google refused the authorization code (invalid_grant)."
        case .http(let status, let message):
            return "Token endpoint returned HTTP \(status)\(message.map { ": \($0)" } ?? "")."
        case .decoding(let reason):
            return "Couldn't decode token response: \(reason)"
        case .transport(let reason):
            return "Network error: \(reason)"
        case .missingResponseField(let field):
            return "Token response missing required field `\(field)`."
        }
    }

    private static func describe(_ error: GoogleCalendarAPIError) -> String {
        switch error {
        case .unauthorized:
            return "access token rejected (401)"
        case .fullSyncRequired:
            return "sync state expired"
        case .notFound:
            return "primary calendar not found"
        case .rateLimited(let retryAfter):
            return "rate-limited\(retryAfter.map { " (retry after \($0)s)" } ?? "")"
        case .http(let status, let body):
            return "HTTP \(status)\(body.map { ": \($0)" } ?? "")"
        case .decoding(let reason):
            return "decode error — \(reason)"
        case .transport(let reason):
            return "network error — \(reason)"
        }
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
