//
//  ShareRulesReader.swift
//  Leaf
//
//  Track 5 / S5 — @Observable wrapper around ShareRulesStore. UI binds to
//  state.loaded(rules:) for per-source toggle rendering;
//  setEnabled(_:enabled:) persists user choice + refreshes state.
//
//  Default semantics (ShareRuleDefaults): when no row exists for (workspace,
//  source), the corresponding source's default ON/OFF state per Track 5
//  contract §11.1 applies. Persisting an override (either direction) creates
//  the row.
//

import Foundation
import Observation
import OSLog
import SwiftUI
import LeafCore
#if LEAF_PROD
import LeafCorePrivate
#endif

@MainActor
@Observable
final class ShareRulesReader {

    enum State: Equatable {
        case loading
        case loaded(rules: [ShareSource: Bool])
        case error(message: String)
    }

    private(set) var state: State = .loading

    private var database: LeafCore.Database?
    private let databaseURL: URL
    private let databaseConfig: DatabaseConfig
    private let databaseEncryption: EncryptionOptions?
    private let activeStore: ActiveWorkspaceStore
    private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "share-rules")

    init(
        activeStore: ActiveWorkspaceStore,
        databaseURL: URL = DatabasePath.defaultURL(),
        databaseConfig: DatabaseConfig = ShareRulesReader.defaultConfig(),
        databaseEncryption: EncryptionOptions? = ShareRulesReader.defaultEncryption()
    ) {
        self.activeStore = activeStore
        self.databaseURL = databaseURL
        self.databaseConfig = databaseConfig
        self.databaseEncryption = databaseEncryption
    }

    func refresh() {
        guard let workspaceID = activeStore.activeWorkspaceID else {
            state = .error(message: "No active workspace.")
            return
        }
        do {
            let db = try ensureDatabase()
            let rules = try db.readShareRules(workspaceID: workspaceID)
            state = .loaded(rules: rules)
        } catch let err as LeafError {
            logger.error("ShareRulesReader.refresh: \(String(describing: err), privacy: .public)")
            state = .error(message: "Couldn't read share rules.")
        } catch {
            logger.error("ShareRulesReader.refresh: \(String(describing: error), privacy: .public)")
            state = .error(message: "Couldn't read share rules.")
        }
    }

    func setEnabled(_ source: ShareSource, enabled: Bool) {
        guard let workspaceID = activeStore.activeWorkspaceID else { return }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        do {
            let db = try ensureDatabase()
            try db.upsertShareRule(
                workspaceID: workspaceID,
                source: source,
                enabled: enabled,
                updatedAtMs: nowMs
            )
            refresh()
        } catch {
            logger.error("ShareRulesReader.setEnabled: \(String(describing: error), privacy: .public)")
            state = .error(message: "Couldn't update setting.")
        }
    }

    // MARK: - Internal

    private func ensureDatabase() throws -> LeafCore.Database {
        if let db = database { return db }
        let db = try LeafCore.Database.openForWrite(
            at: databaseURL, config: databaseConfig, encryption: databaseEncryption
        )
        self.database = db
        return db
    }

    private static func defaultConfig() -> DatabaseConfig {
        #if LEAF_PROD
        return ProdConfigs.database
        #else
        return DatabaseConfig.weakDefaults
        #endif
    }

    private static func defaultEncryption() -> EncryptionOptions? {
        #if LEAF_PROD
        return EncryptionOptions(
            keyProvider: .callback { @Sendable in try FileKeyStore.fetchOrCreate() },
            preKeyPragmas: ProdConfigs.sqlcipherPragmasPreKey,
            postKeyPragmas: ProdConfigs.sqlcipherPragmasPostKey
        )
        #else
        return nil
        #endif
    }
}
