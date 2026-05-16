//
//  BrowserAllowListStore.swift
//  Leaf
//
//  Phase Track-6 P3 — @Observable store for Settings → Browser Allow-list.
//  Wraps CRUD over the `browser_domain_allow` table via Database (writer mode).
//  Pattern mirrors WatchedFoldersService: lazy-open writer + reload after each
//  mutation + optional DistributedNotification to signal adapter invalidation.
//  Task 24 wires the `invalidate` callback into DBDomainAllowListReader.
//

import Foundation
import Observation
import OSLog
import LeafCore
#if LEAF_PROD
import LeafCorePrivate
#endif

/// Value type representing one row in `browser_domain_allow`.
struct BrowserDomainAllowEntry: Identifiable, Equatable {
    var id: String { domain }
    let domain: String
    let granularity: URLGranularity
    let addedAtMs: Int64
    let notes: String?
}

@MainActor
@Observable
final class BrowserAllowListStore {
    private(set) var entries: [BrowserDomainAllowEntry] = []
    private(set) var lastErrorMessage: String?

    /// Optional callback — called after every successful mutation so that
    /// DBDomainAllowListReader can invalidate its cache. Wired in Task 24.
    var onInvalidate: (() -> Void)?

    private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "browser-allow-list")

    private let databaseURL: URL
    private let databaseConfig: DatabaseConfig
    private let databaseEncryption: EncryptionOptions?
    /// Lazy-open writer cached for service lifetime.
    private var database: Database?

    init(
        databaseURL: URL = DatabasePath.defaultURL(),
        databaseConfig: DatabaseConfig = BrowserAllowListStore.defaultConfig(),
        databaseEncryption: EncryptionOptions? = BrowserAllowListStore.defaultEncryption()
    ) {
        self.databaseURL = databaseURL
        self.databaseConfig = databaseConfig
        self.databaseEncryption = databaseEncryption
    }

    // MARK: - Public API

    func load() {
        do {
            let db = try ensureDatabase()
            let rows = try db.listBrowserDomainAllow()
            entries = rows.map {
                BrowserDomainAllowEntry(
                    domain: $0.domain,
                    granularity: $0.granularity,
                    addedAtMs: $0.addedAtMs,
                    notes: $0.notes
                )
            }
            lastErrorMessage = nil
        } catch {
            logger.error("load failed: \(String(describing: error), privacy: .public)")
            lastErrorMessage = "Couldn't read allow-list: \(error.localizedDescription)"
        }
    }

    func add(domain: String, granularity: URLGranularity, notes: String?) {
        let canonical = domain
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonical.isEmpty else { return }
        performWriteWithRetry(operation: "add") { db in
            try db.upsertBrowserDomainAllow(domain: canonical, granularity: granularity, notes: notes)
        }
    }

    func remove(domain: String) {
        performWriteWithRetry(operation: "remove") { db in
            try db.removeBrowserDomainAllow(domain: domain)
        }
    }

    // MARK: - Internals

    private func performWriteWithRetry(operation: String, _ block: (Database) throws -> Void) {
        do {
            let db = try ensureDatabase()
            try block(db)
        } catch {
            Thread.sleep(forTimeInterval: 0.1)
            do {
                let db = try ensureDatabase()
                try block(db)
            } catch {
                logger.error("\(operation, privacy: .public) failed after retry: \(String(describing: error), privacy: .public)")
                lastErrorMessage = "Operation failed: \(error.localizedDescription)"
                load()
                return
            }
        }
        lastErrorMessage = nil
        load()
        onInvalidate?()
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
