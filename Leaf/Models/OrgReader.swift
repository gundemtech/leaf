//
//  OrgReader.swift
//  Leaf
//
//  Phase 5.1.E — @Observable wrapper для OrgService. Открывает events.sqlite
//  в writer-режиме (createPersonalOrg пишет первые row'а в org / team_members /
//  team_keys + keystore файлы), отдаёт текущее состояние через state machine
//  для OrganizationView / TeamView. Mirror InsightsReader composition pattern
//  (defaultConfig / defaultEncryption через LEAF_PROD).
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
final class OrgReader {
    enum State {
        case loading
        case empty
        case loaded(Org, [TeamMember])
        case error(message: String)
    }

    private(set) var state: State = .loading

    private var database: LeafCore.Database?

    private let databaseURL: URL
    private let databaseConfig: DatabaseConfig
    private let databaseEncryption: EncryptionOptions?
    private let keystoreRoot: URL
    private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "org")

    init(
        databaseURL: URL = DatabasePath.defaultURL(),
        databaseConfig: DatabaseConfig = OrgReader.defaultConfig(),
        databaseEncryption: EncryptionOptions? = OrgReader.defaultEncryption(),
        keystoreRoot: URL = TeamKeystore.defaultRoot()
    ) {
        self.databaseURL = databaseURL
        self.databaseConfig = databaseConfig
        self.databaseEncryption = databaseEncryption
        self.keystoreRoot = keystoreRoot
    }

    /// Reads org + members from DB into state. Idempotent. Sync (~ ms).
    func refresh() {
        do {
            let db = try ensureDatabase()
            guard let org = try db.readOrg() else {
                state = .empty
                return
            }
            let members = try db.readTeamMembers(orgID: org.id)
            state = .loaded(org, members)
        } catch {
            logger.error("OrgReader.refresh failed: \(String(describing: error), privacy: .public)")
            state = .error(message: userFacingMessage(for: error))
        }
    }

    /// Synchronous DB+keystore write. State → .loaded(...) on success.
    func createPersonalOrg(displayName: String) {
        do {
            let db = try ensureDatabase()
            let svc = OrgService(database: db, keystoreRoot: keystoreRoot)
            let org = try svc.createPersonalOrg(displayName: displayName)
            let members = try db.readTeamMembers(orgID: org.id)
            state = .loaded(org, members)
        } catch {
            logger.error("OrgReader.createPersonalOrg failed: \(String(describing: error), privacy: .public)")
            state = .error(message: userFacingMessage(for: error))
        }
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
            case .orgAlreadyExists:
                return "An organization already exists on this device."
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
