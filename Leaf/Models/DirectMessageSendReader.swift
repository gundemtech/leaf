//
//  DirectMessageSendReader.swift
//  Leaf
//
//  Track 5 / S4 — @Observable wrapper for DirectMessageService.send. State machine
//  drives SendDirectMessageSheet: .idle → .sending → (.sent / .error).
//
//  Lazy-init pattern mirrors InviteAcceptReader. SupabaseClient injected;
//  Database + service spin up on first send.
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
final class DirectMessageSendReader {
    enum State: Equatable {
        case idle
        case sending
        case sent(messageID: String, status: SentDirectMessage.PushDispatchStatus)
        case error(message: String)
    }

    private(set) var state: State = .idle

    private var service: DirectMessageService?
    private var database: LeafCore.Database?

    private let supabase: SupabaseClient
    private let activeWorkspaceStore: ActiveWorkspaceStore
    private let databaseURL: URL
    private let databaseConfig: DatabaseConfig
    private let databaseEncryption: EncryptionOptions?
    private let keystoreRoot: URL
    private let codec: any DirectMessageBlobCodec
    private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "dm-send")

    init(
        supabase: SupabaseClient,
        activeWorkspaceStore: ActiveWorkspaceStore,
        databaseURL: URL = DatabasePath.defaultURL(),
        databaseConfig: DatabaseConfig = DirectMessageSendReader.defaultConfig(),
        databaseEncryption: EncryptionOptions? = DirectMessageSendReader.defaultEncryption(),
        keystoreRoot: URL = TeamKeystore.defaultRoot(),
        codec: any DirectMessageBlobCodec = DirectMessageSendReader.defaultCodec()
    ) {
        self.supabase = supabase
        self.activeWorkspaceStore = activeWorkspaceStore
        self.databaseURL = databaseURL
        self.databaseConfig = databaseConfig
        self.databaseEncryption = databaseEncryption
        self.keystoreRoot = keystoreRoot
        self.codec = codec
    }

    func reset() {
        state = .idle
    }

    func send(
        recipientPubkeyHex: String,
        recipientMemberID: String?,
        kind: DirectMessageKind,
        body: String,
        notify: Bool
    ) async {
        guard let workspaceID = activeWorkspaceStore.activeWorkspaceID else {
            state = .error(message: "No active workspace")
            return
        }

        state = .sending

        let svc: DirectMessageService
        do {
            svc = try ensureService()
        } catch {
            state = .error(message: "Failed to open DB: \(error)")
            return
        }

        do {
            let result = try await svc.send(
                workspaceID: workspaceID,
                recipientPubkeyHex: recipientPubkeyHex,
                recipientMemberID: recipientMemberID,
                kind: kind,
                body: body,
                notify: notify
            )
            state = .sent(messageID: result.messageID, status: result.pushDispatchStatus)
        } catch let err as LeafError {
            state = .error(message: String(describing: err))
        } catch {
            state = .error(message: String(describing: error))
        }
    }

    // MARK: - Internal lazy bootstrap

    private func ensureService() throws -> DirectMessageService {
        if let s = service { return s }
        let db = try LeafCore.Database.openForWrite(
            at: databaseURL, config: databaseConfig, encryption: databaseEncryption
        )
        let svc = DirectMessageService(
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
