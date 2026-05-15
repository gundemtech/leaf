//
//  TeamEventBroadcastReader.swift
//  Leaf
//
//  Track 5 / S5 — @Observable wrapper around TeamEventBroadcastService.
//  OrganizationView .task(id: workspaceID) drives the 30s tick cadence
//  (mirror of the S4 DM inbox pattern). State surface is observation-only
//  for now; future Settings → Notifications panel can read it.
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
final class TeamEventBroadcastReader {
    enum State: Equatable {
        case idle
        case ticking
        case lastResult(processed: Int, sent: Int, skipped: Int)
        case error(message: String)
    }

    private(set) var state: State = .idle

    private var service: TeamEventBroadcastService?
    private var database: LeafCore.Database?
    private let supabase: SupabaseClient
    private let databaseURL: URL
    private let databaseConfig: DatabaseConfig
    private let databaseEncryption: EncryptionOptions?
    private let keystoreRoot: URL
    private let codecBox: any TeamEventBlobCodec
    private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "team-event-broadcast")

    init(
        supabase: SupabaseClient,
        codec: any TeamEventBlobCodec = TeamEventBroadcastReader.defaultCodec(),
        databaseURL: URL = DatabasePath.defaultURL(),
        databaseConfig: DatabaseConfig = TeamEventBroadcastReader.defaultConfig(),
        databaseEncryption: EncryptionOptions? = TeamEventBroadcastReader.defaultEncryption(),
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
            let svc = try ensureService()
            let result = try await svc.tick(workspaceID: workspaceID)
            state = .lastResult(
                processed: result.processedCount,
                sent: result.sentCount,
                skipped: result.skippedCount
            )
        } catch let err as LeafError {
            state = .error(message: String(describing: err))
            logger.error("broadcast tick failed: \(String(describing: err), privacy: .public)")
        } catch let err as SupabaseError {
            state = .error(message: String(describing: err))
            logger.warning("broadcast tick network failure (will retry next tick): \(String(describing: err), privacy: .public)")
        } catch {
            state = .error(message: String(describing: error))
        }
    }

    // MARK: - Internal

    private func ensureService() throws -> TeamEventBroadcastService {
        if let s = service { return s }
        let db = try LeafCore.Database.openForWrite(
            at: databaseURL, config: databaseConfig, encryption: databaseEncryption
        )
        let svc = TeamEventBroadcastService(
            database: db,
            supabase: supabase,
            codec: codecBox,
            keystoreRoot: keystoreRoot
        )
        self.database = db
        self.service = svc
        return svc
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
