//
//  PendingInvitesReader.swift
//  Leaf
//
//  Phase 5.5.C — @Observable wrapper над PendingInvitesService. Lazy-init Database +
//  RelayClient + service. State machine drives PendingInvitesSection.
//  Mirror InviteOutboxReader (5.2.D) lazy-init pattern + composition root #if LEAF_PROD.
//

import Foundation
import LeafCore
import OSLog
import Observation

#if LEAF_PROD
import LeafCorePrivate
#endif

@MainActor
@Observable
final class PendingInvitesReader {
    enum State: Equatable {
        case loading
        case loaded(rows: [PendingInvite])
        case error(message: String)
    }

    private(set) var state: State = .loading
    /// Section header surface'ит inline ProgressView пока `poll()` в полёте.
    private(set) var isPolling: Bool = false
    /// One-shot user-facing message после poll'а ("Checked 3 — 1 consumed").
    /// Non-blocking — UI читает + clear'ит через .acknowledgePollMessage().
    private(set) var pollMessage: String? = nil

    private var service: PendingInvitesService?
    private var database: LeafCore.Database?

    private let databaseURL: URL
    private let databaseConfig: DatabaseConfig
    private let databaseEncryption: EncryptionOptions?
    private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "pending-invites-reader")

    init(
        databaseURL: URL = DatabasePath.defaultURL(),
        databaseConfig: DatabaseConfig = PendingInvitesReader.defaultConfig(),
        databaseEncryption: EncryptionOptions? = PendingInvitesReader.defaultEncryption()
    ) {
        self.databaseURL = databaseURL
        self.databaseConfig = databaseConfig
        self.databaseEncryption = databaseEncryption
    }

    /// Sync sweep + read. Idempotent — safe to call repeatedly from .onAppear.
    /// Clears any stale poll outcome banner (review fix #4).
    func refresh() {
        pollMessage = nil
        do {
            let svc = try ensureService()
            let rows = try svc.loadVisible()
            state = .loaded(rows: rows)
        } catch {
            logger.error("refresh failed: \(String(describing: error), privacy: .public)")
            state = .error(message: userFacingMessage(for: error))
        }
    }

    /// Async batch poll over .pending rows. Mid-flight rows still rendered.
    func poll() {
        guard !isPolling else { return }
        isPolling = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isPolling = false }
            do {
                let svc = try self.ensureService()
                let outcome = try await svc.pollPending()
                let rows = try svc.loadVisible()
                self.state = .loaded(rows: rows)
                self.pollMessage = self.formatPollOutcome(outcome)
            } catch {
                self.logger.error("poll failed: \(String(describing: error), privacy: .public)")
                self.state = .error(message: self.userFacingMessage(for: error))
            }
        }
    }

    /// Spec D4 — immediate UI feedback. Sync DB flip + state update happen BEFORE
    /// any await; relay DELETE fires in background best-effort task.
    func revoke(token: String) {
        do {
            let svc = try ensureService()
            try svc.revokeLocal(token: token)
            let rows = try svc.loadVisible()
            state = .loaded(rows: rows)
            pollMessage = nil
        } catch {
            logger.error("revoke (local) failed: \(String(describing: error), privacy: .public)")
            state = .error(message: userFacingMessage(for: error))
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let svc = try self.ensureService()
                await svc.tryRelayDelete(token: token)
            } catch {
                self.logger.error("revoke (relay) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func dismiss(token: String) {
        pollMessage = nil
        do {
            let svc = try ensureService()
            try svc.dismiss(token: token)
            let rows = try svc.loadVisible()
            state = .loaded(rows: rows)
        } catch {
            logger.error("dismiss failed: \(String(describing: error), privacy: .public)")
            state = .error(message: userFacingMessage(for: error))
        }
    }

    func acknowledgePollMessage() {
        pollMessage = nil
    }

    // MARK: - Internals

    private func ensureService() throws -> PendingInvitesService {
        if let service { return service }
        let db = try LeafCore.Database.openForWrite(
            at: databaseURL,
            config: databaseConfig,
            encryption: databaseEncryption
        )
        let relay = RelayClient()
        let svc = PendingInvitesService(database: db, relayClient: relay)
        self.database = db
        self.service = svc
        return svc
    }

    private func formatPollOutcome(_ outcome: PollOutcome) -> String {
        let total = outcome.consumed + outcome.stillPending + outcome.networkErrors
        if outcome.networkErrors > 0 && total == outcome.networkErrors {
            return "Couldn’t reach the relay. Try again later."
        }
        if outcome.networkErrors > 0 {
            return "Checked \(total) invites — \(outcome.consumed) consumed, "
                + "\(outcome.stillPending) still awaiting, " + "\(outcome.networkErrors) couldn’t be checked."
        }
        return "Checked \(total) invites — \(outcome.consumed) consumed, " + "\(outcome.stillPending) still awaiting."
    }

    private func userFacingMessage(for error: Error) -> String {
        if let leafErr = error as? LeafError {
            switch leafErr {
            case .databaseUnavailable:
                return "Create your personal org first (Organization tab)."
            case .keyFileUnavailable, .keyFileCorrupted:
                return "Couldn’t access local keystore. Try restarting the app."
            case .relayUnreachable(let reason):
                return "Couldn’t reach the relay (\(reason)). Check your network and try again."
            default:
                return "Couldn’t update invites. See Console for details."
            }
        }
        return "Couldn’t update invites. See Console for details."
    }

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
