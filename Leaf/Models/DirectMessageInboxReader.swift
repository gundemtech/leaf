//
//  DirectMessageInboxReader.swift
//  Leaf
//
//  Track 5 / S4 — @Observable wrapper around DirectMessageInboxService.
//  Periodically polls Supabase for inbound DMs, decrypts, UPSERTs into mirror,
//  publishes recentMessages + unreadCount surfaces for UI.
//
//  Tick cadence: 30s foreground / 5min background. APNs wake → tickOnce.
//

import CryptoKit
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
final class DirectMessageInboxReader {
    private(set) var recentMessages: [DirectMessageMirrorRow] = []
    private(set) var unreadCount: Int = 0
    private(set) var lastTickError: String?

    private var service: DirectMessageInboxService?
    private var database: LeafCore.Database?
    private let supabase: SupabaseClient
    private let activeWorkspaceStore: ActiveWorkspaceStore
    private let databaseURL: URL
    private let databaseConfig: DatabaseConfig
    private let databaseEncryption: EncryptionOptions?
    private let keystoreRoot: URL
    private let codec: any DirectMessageBlobCodec
    private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "dm-inbox")

    init(
        supabase: SupabaseClient,
        activeWorkspaceStore: ActiveWorkspaceStore,
        databaseURL: URL = DatabasePath.defaultURL(),
        databaseConfig: DatabaseConfig = DirectMessageInboxReader.defaultConfig(),
        databaseEncryption: EncryptionOptions? = DirectMessageInboxReader.defaultEncryption(),
        keystoreRoot: URL = TeamKeystore.defaultRoot(),
        codec: any DirectMessageBlobCodec = DirectMessageInboxReader.defaultCodec()
    ) {
        self.supabase = supabase
        self.activeWorkspaceStore = activeWorkspaceStore
        self.databaseURL = databaseURL
        self.databaseConfig = databaseConfig
        self.databaseEncryption = databaseEncryption
        self.keystoreRoot = keystoreRoot
        self.codec = codec
    }

    /// Schedule a full poll + decode + UPSERT cycle.
    func tick() async {
        guard let wid = activeWorkspaceStore.activeWorkspaceID else { return }
        let svc: DirectMessageInboxService
        do {
            svc = try ensureService()
        } catch {
            lastTickError = "DB open failed: \(error)"
            return
        }
        do {
            _ = try await svc.tick(workspaceID: wid)
            refreshLocalState(workspaceID: wid)
            lastTickError = nil
        } catch {
            lastTickError = String(describing: error)
        }
    }

    /// Eager fetch of a single message — driven by APNs wake.
    func tickOnce(workspaceID: String, forMessageID messageID: String) async {
        let svc: DirectMessageInboxService
        do {
            svc = try ensureService()
        } catch {
            lastTickError = "DB open failed: \(error)"
            return
        }
        _ = try? await svc.tickOnce(workspaceID: workspaceID, forMessageID: messageID)
        refreshLocalState(workspaceID: workspaceID)
    }

    /// Refresh published surfaces from local mirror — called after every successful tick.
    func refreshLocalState(workspaceID: String) {
        guard let db = database else { return }
        let pubkey = (try? IdentityService.ensureLocalIdentity(at: keystoreRoot))?
            .publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        do {
            let recent = try db.readSQL {
                try MessagesMirrorStore.readRecent(workspaceID: workspaceID, limit: 50, in: $0)
            }
            recentMessages = recent
            if let pubkey {
                let unread = try db.readSQL {
                    try MessagesMirrorStore.readUnreadInbound(
                        workspaceID: workspaceID, recipientPubkeyHex: pubkey, in: $0
                    )
                }
                unreadCount = unread.count
            }
        } catch {
            logger.error("refreshLocalState failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Internal

    private func ensureService() throws -> DirectMessageInboxService {
        if let s = service { return s }
        let db = try LeafCore.Database.openForWrite(
            at: databaseURL, config: databaseConfig, encryption: databaseEncryption
        )
        let svc = DirectMessageInboxService(
            database: db,
            supabase: supabase,
            codec: codec,
            keystoreRoot: keystoreRoot
        )
        self.database = db
        self.service = svc
        return svc
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

    private static func defaultCodec() -> any DirectMessageBlobCodec {
        #if LEAF_PROD
        return LeafCorePrivate.ProdDirectMessageBlobCodec()
        #else
        return UnimplementedDirectMessageBlobCodec()
        #endif
    }
}
