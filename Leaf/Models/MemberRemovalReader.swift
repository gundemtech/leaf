//
//  MemberRemovalReader.swift
//  Leaf
//
//  Phase 5.3.E — @Observable wrapper for KeyRotationService.removeMember.
//  Lazy-init Database + RelayClient + service. State machine drives
//  RemoveMemberSheet. Mirror InviteOutboxReader (5.2.D) lazy-init pattern +
//  composition root #if LEAF_PROD.
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
final class MemberRemovalReader {
    enum State: Equatable {
        case idle
        case removing(displayName: String)
        case success(outcome: RotationOutcome, displayName: String)
        case error(message: String)
    }

    private(set) var state: State = .idle

    private var service: KeyRotationService?
    private var database: LeafCore.Database?

    private let databaseURL: URL
    private let databaseConfig: DatabaseConfig
    private let databaseEncryption: EncryptionOptions?
    private let keystoreRoot: URL
    private let rotationKDF: any RotationKDF
    private let rotationBlobCodec: any RotationBlobCodec
    private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "member-removal")

    init(
        databaseURL: URL = DatabasePath.defaultURL(),
        databaseConfig: DatabaseConfig = MemberRemovalReader.defaultConfig(),
        databaseEncryption: EncryptionOptions? = MemberRemovalReader.defaultEncryption(),
        keystoreRoot: URL = TeamKeystore.defaultRoot(),
        rotationKDF: any RotationKDF = MemberRemovalReader.defaultRotationKDF(),
        rotationBlobCodec: any RotationBlobCodec = MemberRemovalReader.defaultRotationBlobCodec()
    ) {
        self.databaseURL = databaseURL
        self.databaseConfig = databaseConfig
        self.databaseEncryption = databaseEncryption
        self.keystoreRoot = keystoreRoot
        self.rotationKDF = rotationKDF
        self.rotationBlobCodec = rotationBlobCodec
    }

    func removeMember(memberID: String, displayName: String) {
        state = .removing(displayName: displayName)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let svc = try self.ensureService()
                let outcome = try await svc.removeMember(memberID: memberID)
                self.state = .success(outcome: outcome, displayName: displayName)
            } catch {
                self.logger.error("removeMember failed: \(String(describing: error), privacy: .public)")
                self.state = .error(message: self.userFacingMessage(for: error))
            }
        }
    }

    func dismiss() {
        state = .idle
    }

    // MARK: - Internals

    private func ensureService() throws -> KeyRotationService {
        if let service { return service }
        let db = try LeafCore.Database.openForWrite(
            at: databaseURL,
            config: databaseConfig,
            encryption: databaseEncryption
        )
        let relay = RelayClient()
        let svc = KeyRotationService(
            database: db,
            relayClient: relay,
            rotationKDF: rotationKDF,
            rotationBlobCodec: rotationBlobCodec,
            keystoreRoot: keystoreRoot
        )
        self.database = db
        self.service = svc
        return svc
    }

    private func userFacingMessage(for error: Error) -> String {
        if let leafErr = error as? LeafError {
            switch leafErr {
            case .cannotRemoveSelfFromTeam:
                return "You can’t remove yourself from your own team."
            case .invalidPayload:
                return "Couldn’t remove member. Local state may be out of sync — try restarting the app."
            case .keyFileUnavailable, .keyFileCorrupted:
                return "Couldn’t access local keystore. Try restarting the app."
            case .relayUnreachable(let reason):
                return "Couldn’t reach the relay (\(reason)). Member removed locally; rotation will retry on next tick."
            case .rotationRequestRejected(let reason):
                return "Rotation request rejected (\(reason))."
            case .databaseUnavailable:
                return "Couldn’t open local database. Try restarting the app."
            case .notImplemented:
                return "Member removal isn’t available in this build."
            default:
                return "Couldn’t remove member. See Console for details."
            }
        }
        return "Couldn’t remove member. See Console for details."
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

    nonisolated private static func defaultRotationKDF() -> any RotationKDF {
        #if LEAF_PROD
        return ProdRotationKDF()
        #else
        return UnimplementedRotationKDF()
        #endif
    }

    nonisolated private static func defaultRotationBlobCodec() -> any RotationBlobCodec {
        #if LEAF_PROD
        return ProdRotationBlobCodec()
        #else
        return UnimplementedRotationBlobCodec()
        #endif
    }
}
