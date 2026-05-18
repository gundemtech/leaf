//
//  TeamEventMirrorReader.swift
//  Leaf
//
//  Track 5 / S5 — @Observable wrapper around TeamEventMirrorService +
//  TeamEventMirrorRetentionPruner. OrganizationView .task drives 30s
//  inbound mirror tick (matches DM inbox cadence). Retention pruner ticks
//  once per launch + daily.
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
final class TeamEventMirrorReader {
    enum State: Equatable {
        case idle
        case ticking
        case lastResult(fetched: Int, decoded: Int, upserted: Int)
        case error(message: String)
    }

    private(set) var state: State = .idle
    private(set) var lastPrunedAt: Date?
    private(set) var lastPruneRemoved: Int = 0

    private var mirrorService: TeamEventMirrorService?
    private var retentionPruner: TeamEventMirrorRetentionPruner?
    private var database: LeafCore.Database?
    private let supabase: SupabaseClient
    private let databaseURL: URL
    private let databaseConfig: DatabaseConfig
    private let databaseEncryption: EncryptionOptions?
    private let keystoreRoot: URL
    private let codecBox: any TeamEventBlobCodec
    private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "team-event-mirror")

    init(
        supabase: SupabaseClient,
        codec: any TeamEventBlobCodec = TeamEventMirrorReader.defaultCodec(),
        databaseURL: URL = DatabasePath.defaultURL(),
        databaseConfig: DatabaseConfig = TeamEventMirrorReader.defaultConfig(),
        databaseEncryption: EncryptionOptions? = TeamEventMirrorReader.defaultEncryption(),
        keystoreRoot: URL = TeamKeystore.defaultRoot()
    ) {
        self.supabase = supabase
        self.codecBox = codec
        self.databaseURL = databaseURL
        self.databaseConfig = databaseConfig
        self.databaseEncryption = databaseEncryption
        self.keystoreRoot = keystoreRoot
    }

    func tick(workspaceID: String) async {
        state = .ticking
        do {
            let svc = try ensureMirror()
            let result = try await svc.tick(workspaceID: workspaceID)
            state = .lastResult(
                fetched: result.fetchedCount,
                decoded: result.decodedCount,
                upserted: result.upsertedCount
            )
        } catch let err as LeafError {
            state = .error(message: String(describing: err))
        } catch let err as SupabaseError {
            state = .error(message: String(describing: err))
            logger.warning("mirror tick network failure: \(String(describing: err), privacy: .public)")
        } catch {
            state = .error(message: String(describing: error))
        }
    }

    /// Realtime push handler — UPSERTs a single team event row.
    /// Called by LeafRealtimeService when a Realtime POSTGRES_CHANGES INSERT event
    /// fires on `team_events` for this device's workspace.
    ///
    /// C2/C3 plaintext-trust gates (senderPubkeyHex + workspaceID verification)
    /// are applied by the caller (LeafRealtimeService) before routing here.
    /// Falls back gracefully: logs + skips on service unavailability or decode error.
    func absorbRealtimePush(_ row: TeamEventMirrorRow) async {
        do {
            let svc = try ensureMirror()
            try await svc.absorbRealtimePush(row)
        } catch {
            logger.error("team event realtime push failed: \(String(describing: error), privacy: .public)")
        }
    }

    func pruneIfDueDaily(now: Date = Date()) async {
        if let last = lastPrunedAt, now.timeIntervalSince(last) < 86_400 {
            return
        }
        do {
            let p = try ensurePruner()
            let removed = try await p.prune()
            lastPruneRemoved = removed
            lastPrunedAt = now
        } catch {
            logger.error("mirror prune failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Internal

    private func ensureMirror() throws -> TeamEventMirrorService {
        if let s = mirrorService { return s }
        let db = try ensureDatabase()
        let svc = TeamEventMirrorService(
            database: db, supabase: supabase, codec: codecBox, keystoreRoot: keystoreRoot
        )
        self.mirrorService = svc
        return svc
    }

    private func ensurePruner() throws -> TeamEventMirrorRetentionPruner {
        if let p = retentionPruner { return p }
        let db = try ensureDatabase()
        let p = TeamEventMirrorRetentionPruner(database: db)
        self.retentionPruner = p
        return p
    }

    private func ensureDatabase() throws -> LeafCore.Database {
        if let db = database { return db }
        let db = try LeafCore.Database.openForWrite(
            at: databaseURL, config: databaseConfig, encryption: databaseEncryption
        )
        self.database = db
        return db
    }

    nonisolated private static func defaultConfig() -> DatabaseConfig {
        #if LEAF_PROD
        return ProdConfigs.database
        #else
        return DatabaseConfig.weakDefaults
        #endif
    }

    nonisolated private static func defaultEncryption() -> EncryptionOptions? {
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

    nonisolated private static func defaultCodec() -> any TeamEventBlobCodec {
        #if LEAF_PROD
        return ProdTeamEventBlobCodec()
        #else
        return UnimplementedTeamEventBlobCodec()
        #endif
    }
}
