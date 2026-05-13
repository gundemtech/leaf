//
//  InviteOutboxReader.swift
//  Leaf
//
//  Phase 5.2.D — @Observable wrapper для InviteService. Lazy-init Database +
//  RelayClient + InviteService. State machine drives GenerateInviteSheet.
//  Mirror OrgReader (5.1.E) lazy-init pattern + composition root #if LEAF_PROD.
//

import Foundation
import Observation
import OSLog
import LeafCore
#if LEAF_PROD
import LeafCorePrivate
#endif

@MainActor
@Observable
final class InviteOutboxReader {
    enum State: Equatable {
        case idle
        case generating
        case ready(InviteOutbound)
        case error(message: String)
    }

    private(set) var state: State = .idle

    private var service: InviteService?
    private var database: LeafCore.Database?

    private let databaseURL: URL
    private let databaseConfig: DatabaseConfig
    private let databaseEncryption: EncryptionOptions?
    private let keystoreRoot: URL
    private let inviteKDF: any InviteKDF
    private let inviteBlobCodec: any InviteBlobCodec
    private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "invite-outbox")

    init(
        databaseURL: URL = DatabasePath.defaultURL(),
        databaseConfig: DatabaseConfig = InviteOutboxReader.defaultConfig(),
        databaseEncryption: EncryptionOptions? = InviteOutboxReader.defaultEncryption(),
        keystoreRoot: URL = TeamKeystore.defaultRoot(),
        inviteKDF: any InviteKDF = InviteOutboxReader.defaultInviteKDF(),
        inviteBlobCodec: any InviteBlobCodec = InviteOutboxReader.defaultInviteBlobCodec()
    ) {
        self.databaseURL = databaseURL
        self.databaseConfig = databaseConfig
        self.databaseEncryption = databaseEncryption
        self.keystoreRoot = keystoreRoot
        self.inviteKDF = inviteKDF
        self.inviteBlobCodec = inviteBlobCodec
    }

    func generate(inviteePubkeyHex: String) {
        let trimmed = inviteePubkeyHex.trimmingCharacters(in: .whitespacesAndNewlines)
        state = .generating
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let svc = try self.ensureService()
                // Track-5 S2: resolve workspace from DB. Single-workspace
                // assumption holds until Task 10 wires ActiveWorkspaceStore
                // through this reader.
                let workspaceID = try self.resolveWorkspaceID()
                let outbound = try await svc.generateInvite(
                    workspaceID: workspaceID,
                    inviteePubkeyHex: trimmed
                )
                self.persistPendingInvite(outbound)
                self.state = .ready(outbound)
            } catch {
                self.logger.error("generateInvite failed: \(String(describing: error), privacy: .public)")
                self.state = .error(message: self.userFacingMessage(for: error))
            }
        }
    }

    /// Phase 5.5.B — accept formatted JoinCode (or legacy hex) directly.
    func generate(inviteeJoinCode: String) {
        let trimmed = inviteeJoinCode.trimmingCharacters(in: .whitespacesAndNewlines)
        state = .generating
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let svc = try self.ensureService()
                let workspaceID = try self.resolveWorkspaceID()
                let outbound = try await svc.generateInvite(
                    workspaceID: workspaceID,
                    inviteeJoinCode: trimmed
                )
                self.persistPendingInvite(outbound)
                self.state = .ready(outbound)
            } catch {
                self.logger.error("generateInvite(joinCode) failed: \(String(describing: error), privacy: .public)")
                self.state = .error(message: self.userFacingMessage(for: error))
            }
        }
    }

    /// Transitional workspace resolver — picks the first workspace until
    /// Task 10 wires `ActiveWorkspaceStore` into this reader.
    private func resolveWorkspaceID() throws -> String {
        guard let db = self.database,
              let workspace = try db.listWorkspaces(includeLeft: true).first else {
            throw LeafError.databaseUnavailable
        }
        return workspace.id
    }

    func revokeAndDismiss() {
        guard case .ready(let outbound) = state else {
            state = .idle
            return
        }
        let token = outbound.token
        state = .idle
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let svc = try self.ensureService()
                try await svc.revokeInvite(token: token)
                self.markPendingInviteRevoked(token: token)
            } catch {
                self.logger.error("revokeInvite (best-effort) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func dismiss() {
        state = .idle
    }

    // MARK: - Pending invites persistence (Phase 5.5.B)

    private func persistPendingInvite(_ outbound: InviteOutbound) {
        guard let db = self.database else { return }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let row = PendingInvite(
            token: outbound.token,
            otp: outbound.otp,
            inviteePubkeyHex: outbound.inviteePubkeyHex,
            inviteeDisplayNameHint: nil,
            createdAtMs: nowMs,
            expiresAtMs: outbound.expiresAtMs,
            status: .pending,
            lastPolledAtMs: nil
        )
        do {
            try db.insertPendingInvite(row)
        } catch {
            logger.error("persistPendingInvite failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func markPendingInviteRevoked(token: String) {
        guard let db = self.database else { return }
        do {
            try db.updatePendingInviteStatus(token: token, status: .revoked)
        } catch {
            logger.error("markPendingInviteRevoked failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Internals

    private func ensureService() throws -> InviteService {
        if let service { return service }
        let db = try LeafCore.Database.openForWrite(
            at: databaseURL,
            config: databaseConfig,
            encryption: databaseEncryption
        )
        let relay = RelayClient()
        let svc = InviteService(
            database: db,
            relayClient: relay,
            inviteKDF: inviteKDF,
            inviteBlobCodec: inviteBlobCodec,
            keystoreRoot: keystoreRoot
        )
        self.database = db
        self.service = svc
        return svc
    }

    private func userFacingMessage(for error: Error) -> String {
        if let leafErr = error as? LeafError {
            switch leafErr {
            case .invalidPayload:
                return "Invitee public key must be 64 hex characters."
            case .databaseUnavailable:
                return "Create your personal org first (Organization tab)."
            case .keyFileUnavailable, .keyFileCorrupted:
                return "Couldn’t access local keystore. Try restarting the app."
            case .relayUnreachable(let reason):
                return "Couldn’t reach the relay (\(reason)). Check your network and try again."
            case .inviteRequestRejected(let reason):
                return "Invite request rejected (\(reason))."
            case .joinCodeMalformed:
                return "Invitee Join code is unrecognized. Ask invitee to copy it again from app."
            case .joinCodeChecksumMismatch:
                return "Invitee Join code has typos. Ask invitee to copy it again."
            case .notImplemented:
                return "Invite generation isn’t available in this build."
            default:
                return "Couldn’t generate the invite. See Console for details."
            }
        }
        return "Couldn’t generate the invite. See Console for details."
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

    nonisolated private static func defaultInviteKDF() -> any InviteKDF {
        #if LEAF_PROD
        return ProdInviteKDF()
        #else
        return UnimplementedInviteKDF()
        #endif
    }

    nonisolated private static func defaultInviteBlobCodec() -> any InviteBlobCodec {
        #if LEAF_PROD
        return ProdInviteBlobCodec()
        #else
        return UnimplementedInviteBlobCodec()
        #endif
    }
}
