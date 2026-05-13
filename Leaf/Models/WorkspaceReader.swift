//
//  WorkspaceReader.swift
//  Leaf
//
//  Phase Track-5 S2 — multi-workspace @Observable adapter (replaces OrgReader).
//  State machine spans no-workspaces → multi-workspace + active + members.
//  Subscribes to ActiveWorkspaceStore for active-workspace observation.
//  Self-removed detection per active workspace mirrors Phase 5.3.E.
//

import CryptoKit
import Foundation
import Observation
import OSLog
import LeafCore
#if LEAF_PROD
import LeafCorePrivate
#endif

@MainActor
@Observable
final class WorkspaceReader {
    enum State: Equatable {
        case loading
        case empty                                                  // no workspaces — onboarding
        case loaded(workspaces: [Workspace], active: Workspace, members: [TeamMember])
        case removedFromActiveWorkspace(workspaceName: String)
        case error(message: String)
    }

    private(set) var state: State = .loading

    private var database: LeafCore.Database?

    private let databaseURL: URL
    private let databaseConfig: DatabaseConfig
    private let databaseEncryption: EncryptionOptions?
    private let keystoreRoot: URL
    private let activeStore: ActiveWorkspaceStore
    private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "workspace")

    init(
        databaseURL: URL = DatabasePath.defaultURL(),
        databaseConfig: DatabaseConfig = WorkspaceReader.defaultConfig(),
        databaseEncryption: EncryptionOptions? = WorkspaceReader.defaultEncryption(),
        keystoreRoot: URL = TeamKeystore.defaultRoot(),
        activeStore: ActiveWorkspaceStore
    ) {
        self.databaseURL = databaseURL
        self.databaseConfig = databaseConfig
        self.databaseEncryption = databaseEncryption
        self.keystoreRoot = keystoreRoot
        self.activeStore = activeStore
    }

    /// Reads workspaces + active members from DB into state. Idempotent.
    func refresh() {
        do {
            let db = try ensureDatabase()
            let workspaces = try db.listWorkspaces(includeLeft: false)
            guard !workspaces.isEmpty else {
                state = .empty
                return
            }

            // Resolve active workspace (post-M019 first launch fills the UD key
            // via backfillIfNeeded; subsequent launches read the stored id).
            try activeStore.backfillIfNeeded(database: db)
            guard let activeID = activeStore.activeWorkspaceID,
                  let active = workspaces.first(where: { $0.id == activeID }) else {
                state = .error(message: "Couldn’t resolve active workspace.")
                return
            }

            // Self-removed detection per active workspace (Phase 5.3.E pattern).
            let allMembers = try db.readTeamMembers(workspaceID: active.id, includeRemoved: true)
            let priv = try IdentityService.ensureLocalIdentity(at: keystoreRoot)
            let myPubHex = priv.publicKey.rawRepresentation
                .map { String(format: "%02x", $0) }.joined()
            if let selfMember = allMembers.first(where: { $0.pubkeyHex == myPubHex }),
               selfMember.removedAt != nil {
                state = .removedFromActiveWorkspace(workspaceName: active.name)
                return
            }

            let activeMembers = allMembers.filter { $0.removedAt == nil }
            state = .loaded(workspaces: workspaces, active: active, members: activeMembers)
        } catch {
            logger.error("WorkspaceReader.refresh failed: \(String(describing: error), privacy: .public)")
            state = .error(message: userFacingMessage(for: error))
        }
    }

    /// Creates a new workspace, sets it as active, refreshes state.
    func createWorkspace(displayName: String) {
        do {
            let db = try ensureDatabase()
            let svc = WorkspaceService(database: db, keystoreRoot: keystoreRoot)
            let workspace = try svc.createWorkspace(displayName: displayName)
            activeStore.setActive(workspace.id)
            refresh()
        } catch {
            logger.error("WorkspaceReader.createWorkspace failed: \(String(describing: error), privacy: .public)")
            state = .error(message: userFacingMessage(for: error))
        }
    }

    /// Switches active workspace. Idempotent. Refreshes state.
    func switchActive(to workspaceID: String) {
        activeStore.setActive(workspaceID)
        refresh()
    }

    // MARK: - Internals

    private func ensureDatabase() throws -> LeafCore.Database {
        if let database { return database }
        let db = try LeafCore.Database.openForWrite(
            at: databaseURL,
            config: databaseConfig,
            encryption: databaseEncryption
        )
        self.database = db
        return db
    }

    private func userFacingMessage(for error: Error) -> String {
        if let leafErr = error as? LeafError {
            switch leafErr {
            case .invalidPayload:
                return "Workspace name can’t be empty."
            case .keyFileUnavailable, .keyFileCorrupted:
                return "Couldn’t access local keystore. Try restarting the app."
            case .keychainUnavailable:
                return "Couldn’t generate secure random data. Try again."
            default:
                return "Couldn’t complete the operation. See Console for details."
            }
        }
        return "Couldn’t complete the operation. See Console for details."
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
