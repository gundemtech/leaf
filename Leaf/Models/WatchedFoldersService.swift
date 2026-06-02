//
//  WatchedFoldersService.swift
//  Leaf
//
//  Phase 2.4 — @Observable controller for the UI Settings → Folders tab.
//  Opens the Database in writer mode, supports CRUD over `watched_folders`,
//  and posts a DistributedNotification after a change so the Agent restarts
//  FSEventStream.
//

import Foundation
import SwiftUI
import OSLog
import LeafCore
#if LEAF_PROD
import LeafCorePrivate
#endif

@MainActor
@Observable
final class WatchedFoldersService {
    private(set) var folders: [WatchedFolder] = []
    private(set) var lastErrorMessage: String?

    private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "watched-folders")
    private let restartTriggerName: String

    private let databaseURL: URL
    private let databaseConfig: DatabaseConfig
    private let databaseEncryption: EncryptionOptions?
    /// Lazy-open writer cached for the service's lifetime. Closed on dealloc.
    private var database: Database?

    init(
        databaseURL: URL = DatabasePath.defaultURL(),
        databaseConfig: DatabaseConfig = WatchedFoldersService.defaultConfig(),
        databaseEncryption: EncryptionOptions? = WatchedFoldersService.defaultEncryption(),
        restartTriggerName: String = "tech.gundem.leaf.watched-folders-changed"
    ) {
        self.databaseURL = databaseURL
        self.databaseConfig = databaseConfig
        self.databaseEncryption = databaseEncryption
        self.restartTriggerName = restartTriggerName
    }

    // MARK: - Public API

    /// Re-reads state from the DB (after add/remove/update or a manual refresh).
    /// `database` lazy-opens on the first call.
    func reload() {
        do {
            let db = try ensureDatabase()
            folders = try db.listWatchedFolders(includingDisabled: true)
            lastErrorMessage = nil
        } catch {
            logger.error("reload failed: \(String(describing: error), privacy: .public)")
            lastErrorMessage = "Couldn't read folders: \(error.localizedDescription)"
        }
    }

    /// Add folder. `path` is canonicalized (resolvingSymlinksInPath) before INSERT.
    /// UNIQUE conflict (folder already added) → lastErrorMessage updates.
    func add(path: String, granularity: WatchedFolderGranularity = .L4) {
        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let now = Date()
        let folder = WatchedFolder(
            id: UUID().uuidString,
            path: canonical,
            maxGranularity: granularity,
            enabled: true,
            addedAt: now,
            updatedAt: now
        )
        performWriteWithRetry(operation: "add") { db in
            try db.addWatchedFolder(folder)
        }
    }

    func remove(id: String) {
        performWriteWithRetry(operation: "remove") { db in
            try db.removeWatchedFolder(id: id)
        }
    }

    func update(id: String, enabled: Bool? = nil, granularity: WatchedFolderGranularity? = nil) {
        performWriteWithRetry(operation: "update") { db in
            try db.updateWatchedFolder(id: id, enabled: enabled, maxGranularity: granularity)
        }
    }

    // MARK: - Internals

    /// Phase 2.4 R6: SQLite multi-process write — App is the second writer alongside
    /// the Agent. busyTimeout serializes them, but on a conflict, gracefully retry once
    /// after a 100ms backoff. The final failure surfaces in the UI.
    private func performWriteWithRetry(operation: String, _ block: (Database) throws -> Void) {
        do {
            let db = try ensureDatabase()
            try block(db)
        } catch {
            // Retry once for SQLite busy.
            Thread.sleep(forTimeInterval: 0.1)
            do {
                let db = try ensureDatabase()
                try block(db)
            } catch {
                logger.error("\(operation, privacy: .public) failed after retry: \(String(describing: error), privacy: .public)")
                lastErrorMessage = "Operation failed: \(error.localizedDescription)"
                reload()
                return
            }
        }
        lastErrorMessage = nil
        reload()
        postRestartNotification()
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
