//
//  JoinRequestsReader.swift
//  Leaf
//
//  M027 invite-redesign — @Observable wrapper around JoinRequestService.
//  Drives both admin's PendingRequestsSection queue + invitee's
//  JoinRequestWaitingCard state machine.
//

import Foundation
import Observation
import OSLog
import CryptoKit
import LeafCore
#if LEAF_PROD
import LeafCorePrivate
#endif

@MainActor
@Observable
final class JoinRequestsReader {
    enum AdminQueueState: Equatable {
        case idle
        case loading
        case loaded([JoinRequest])
        case error(message: String)
    }

    enum InviteeWaitingState: Equatable {
        case idle
        case submitting
        case pending(JoinRequest)
        case approved(JoinRequest)
        case declined
        case cancelled
        case expired
        case error(message: String)
    }

    private(set) var adminQueue: AdminQueueState = .idle
    private(set) var inviteeState: InviteeWaitingState = .idle

    private var service: JoinRequestService?
    private var database: LeafCore.Database?

    private let supabase: SupabaseClient
    private let activeWorkspaceStore: ActiveWorkspaceStore
    private let databaseURL: URL
    private let databaseConfig: DatabaseConfig
    private let databaseEncryption: EncryptionOptions?
    private let keystoreRoot: URL
    private let inviteKDF: any InviteKDF
    private let inviteBlobCodec: any InviteBlobCodec
    private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "join-requests")

    init(
        supabase: SupabaseClient,
        activeWorkspaceStore: ActiveWorkspaceStore,
        databaseURL: URL = DatabasePath.defaultURL(),
        databaseConfig: DatabaseConfig = JoinRequestsReader.defaultConfig(),
        databaseEncryption: EncryptionOptions? = JoinRequestsReader.defaultEncryption(),
        keystoreRoot: URL = TeamKeystore.defaultRoot(),
        inviteKDF: any InviteKDF = JoinRequestsReader.defaultInviteKDF(),
        inviteBlobCodec: any InviteBlobCodec = JoinRequestsReader.defaultInviteBlobCodec()
    ) {
        self.supabase = supabase
        self.activeWorkspaceStore = activeWorkspaceStore
        self.databaseURL = databaseURL
        self.databaseConfig = databaseConfig
        self.databaseEncryption = databaseEncryption
        self.keystoreRoot = keystoreRoot
        self.inviteKDF = inviteKDF
        self.inviteBlobCodec = inviteBlobCodec
    }

    // MARK: - Admin queue API

    func refreshAdminQueue() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let svc = try self.ensureService()
                guard let workspaceID = self.activeWorkspaceStore.activeWorkspaceID else {
                    self.adminQueue = .loaded([])
                    return
                }
                self.adminQueue = .loading
                let pending = try await svc.listPending(workspaceID: workspaceID)
                self.adminQueue = .loaded(pending)
            } catch {
                self.logger.error("refreshAdminQueue: \(String(describing: error), privacy: .public)")
                self.adminQueue = .error(message: friendlyMessage(for: error))
            }
        }
    }

    func approve(request: JoinRequest) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let svc = try self.ensureService()
                try await svc.approve(
                    workspaceID: request.workspaceID,
                    requestID: request.requestID,
                    inviteePubkeyHex: request.inviteePubkeyHex
                )
                self.refreshAdminQueue()
            } catch {
                self.logger.error("approve: \(String(describing: error), privacy: .public)")
                self.adminQueue = .error(message: friendlyMessage(for: error))
            }
        }
    }

    func decline(requestID: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let svc = try self.ensureService()
                try await svc.decline(requestID: requestID)
                self.refreshAdminQueue()
            } catch {
                self.logger.error("decline: \(String(describing: error), privacy: .public)")
                self.adminQueue = .error(message: friendlyMessage(for: error))
            }
        }
    }

    func approveAll(requests: [JoinRequest]) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let svc = try self.ensureService()
                for req in requests {
                    try await svc.approve(
                        workspaceID: req.workspaceID,
                        requestID: req.requestID,
                        inviteePubkeyHex: req.inviteePubkeyHex
                    )
                }
                self.refreshAdminQueue()
            } catch {
                self.logger.error("approveAll: \(String(describing: error), privacy: .public)")
                self.adminQueue = .error(message: friendlyMessage(for: error))
            }
        }
    }

    func declineAll(requestIDs: [String]) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let svc = try self.ensureService()
                for id in requestIDs {
                    try await svc.decline(requestID: id)
                }
                self.refreshAdminQueue()
            } catch {
                self.logger.error("declineAll: \(String(describing: error), privacy: .public)")
                self.adminQueue = .error(message: friendlyMessage(for: error))
            }
        }
    }

    // MARK: - Invitee waiting-card API

    func submit(workspaceID: String? = nil, code: String, displayName: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.inviteeState = .submitting
            do {
                let svc = try self.ensureService()
                let row = try await svc.submit(
                    workspaceID: workspaceID, code: code, displayName: displayName
                )
                self.inviteeState = .pending(row)
            } catch {
                self.logger.error("submit: \(String(describing: error), privacy: .public)")
                self.inviteeState = .error(message: friendlyMessage(for: error))
            }
        }
    }

    func cancelOwn(requestID: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let svc = try self.ensureService()
                try await svc.cancel(requestID: requestID)
                self.inviteeState = .cancelled
            } catch {
                self.logger.error("cancelOwn: \(String(describing: error), privacy: .public)")
                self.inviteeState = .error(message: friendlyMessage(for: error))
            }
        }
    }

    /// Polls own request status (30s tick from JoinRequestWaitingCard).
    /// Transitions inviteeState as the server-side status flips.
    func pollOwn(requestID: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let svc = try self.ensureService()
                guard let row = try await svc.fetchOwn(requestID: requestID) else {
                    // Row vanished — treat as cancelled (most likely path: invitee
                    // cancelled from another device, OR admin hard-deleted token
                    // and request cascades).
                    self.inviteeState = .cancelled
                    return
                }
                switch row.status {
                case .pending:    self.inviteeState = .pending(row)
                case .approved:   self.inviteeState = .approved(row)
                case .declined:   self.inviteeState = .declined
                case .cancelled:  self.inviteeState = .cancelled
                case .expired:    self.inviteeState = .expired
                }
            } catch {
                self.logger.error("pollOwn: \(String(describing: error), privacy: .public)")
                self.inviteeState = .error(message: friendlyMessage(for: error))
            }
        }
    }

    func resetInviteeState() {
        inviteeState = .idle
    }

    // MARK: - Lazy init

    private func ensureService() throws -> JoinRequestService {
        if let svc = service { return svc }
        let db = try ensureDatabase()
        let svc = JoinRequestService(
            database: db,
            supabase: supabase,
            inviteKDF: inviteKDF,
            inviteBlobCodec: inviteBlobCodec,
            keystoreRoot: keystoreRoot
        )
        service = svc
        return svc
    }

    private func ensureDatabase() throws -> LeafCore.Database {
        if let db = database { return db }
        let db = try LeafCore.Database.openForWrite(
            at: databaseURL, config: databaseConfig, encryption: databaseEncryption
        )
        database = db
        return db
    }

    // MARK: - Composition root defaults

    nonisolated static func defaultConfig() -> DatabaseConfig {
        #if LEAF_PROD
        return ProdConfigs.database
        #else
        return .weakDefaults
        #endif
    }

    nonisolated static func defaultEncryption() -> EncryptionOptions? {
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

    nonisolated static func defaultInviteKDF() -> any InviteKDF {
        #if LEAF_PROD
        return ProdInviteKDF()
        #else
        return UnimplementedInviteKDF()
        #endif
    }

    nonisolated static func defaultInviteBlobCodec() -> any InviteBlobCodec {
        #if LEAF_PROD
        return ProdInviteBlobCodec()
        #else
        return UnimplementedInviteBlobCodec()
        #endif
    }

    // MARK: - Helpers

    private func friendlyMessage(for error: Error) -> String {
        if let leafErr = error as? LeafError {
            return leafErr.localizedDescription
        }
        if let supabaseErr = error as? SupabaseError {
            switch supabaseErr {
            case .forbidden: return "Not authorized for this action."
            case .noRowsAffected: return "This invite is no longer valid."
            case .transport(let reason): return "Network error: \(reason)"
            case .unauthorized: return "Not signed in to Supabase. Restart the app."
            case .authBootstrapFailed(let reason): return "Auth bootstrap failed: \(reason)"
            case .identityClaimMissing: return "JWT missing pubkey claim — Auth Hook race. Restart the app."
            case .decoding(let reason): return "Response decoding failed: \(reason)"
            case .unexpected(let status): return "Unexpected server status \(status)."
            case .badRequest: return "Bad request — client sent invalid payload."
            case .notFound: return "Endpoint not found — Edge Function may not be deployed."
            case .conflict: return "Conflict — duplicate request."
            case .rateLimited: return "Rate limited. Wait and try again."
            case .serverError: return "Server error (5xx)."
            case .pubkeyAlreadyRegistered: return "Pubkey collision."
            case .inviteNotResolvable: return "Invite expired or claimed."
            }
        }
        return "Something went wrong: \(String(describing: error).prefix(120))"
    }
}
