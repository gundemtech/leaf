//
//  ChatStore.swift
//  Team chats — @Observable surface for the hub Chats tab. Reads the
//  conversation list (roster ∪ per-peer summaries) and the selected 1:1
//  conversation from the local messages_mirror; pure transforms live in
//  LeafCore (ChatListPresentation / MessagesMirrorStore.readConversation —
//  TDD'd there, app target has no test bundle).
//
//  Refresh triggers (wired in ChatsTab):
//    • .task(id: activeWorkspaceID) — workspace switch / tab mount
//    • .onChange(of: inboxReader.recentMessages) — polling tick, Realtime
//      absorb, markRead/markDone all republish that surface
//    • after own send (DirectMessageSendReader reaches .sent)
//
//  Read-only DB handle (openForRead) — all writes stay with the existing
//  services (DirectMessageService / DirectMessageInboxReader.markRead).
//

import Foundation
import LeafCore
import Observation
import OSLog

#if LEAF_PROD
  import LeafCorePrivate
#endif

@MainActor
@Observable
final class ChatStore {
  private(set) var conversations: [ChatConversation] = []
  /// Selected counterpart (pubkey hex). Nil → Activity pseudo-chat.
  private(set) var selectedPeer: String?
  /// Selected 1:1 conversation, ascending (oldest → newest).
  private(set) var messages: [DirectMessageMirrorRow] = []
  private(set) var lastError: String?

  private var database: LeafCore.Database?
  private let databaseURL: URL
  private let databaseConfig: DatabaseConfig
  private let databaseEncryption: EncryptionOptions?
  private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "chat-store")

  init(
    databaseURL: URL = DatabasePath.defaultURL(),
    databaseConfig: DatabaseConfig = ChatStore.defaultConfig(),
    databaseEncryption: EncryptionOptions? = ChatStore.defaultEncryption()
  ) {
    self.databaseURL = databaseURL
    self.databaseConfig = databaseConfig
    self.databaseEncryption = databaseEncryption
  }

  // MARK: - Refresh

  /// Rebuild the conversation list and (when a peer is selected) reload its
  /// thread. Cheap local reads — safe to call on every inbox republish.
  func refresh(workspaceID: String, members: [TeamMember], selfPubkeyHex: String) {
    do {
      let db = try ensureDatabase()
      let summaries = try db.readSQL {
        try MessagesMirrorStore.conversationSummaries(workspaceID: workspaceID, in: $0)
      }
      conversations = ChatListPresentation.conversations(
        members: members, summaries: summaries, selfPubkeyHex: selfPubkeyHex)
      lastError = nil
      if let peer = selectedPeer {
        loadMessages(workspaceID: workspaceID, peer: peer)
      }
    } catch {
      logger.error("chat refresh failed: \(String(describing: error))")
      lastError = "Couldn't load chats."
    }
  }

  func select(peer: String?, workspaceID: String) {
    selectedPeer = peer
    messages = []
    if let peer {
      loadMessages(workspaceID: workspaceID, peer: peer)
    }
  }

  /// Workspace switch — drop selection so the pane doesn't show another
  /// workspace's thread.
  func resetSelection() {
    selectedPeer = nil
    messages = []
  }

  private func loadMessages(workspaceID: String, peer: String) {
    do {
      let db = try ensureDatabase()
      messages = try db.readSQL {
        try MessagesMirrorStore.readConversation(
          workspaceID: workspaceID, peerPubkeyHex: peer, in: $0)
      }
    } catch {
      logger.error("chat thread load failed: \(String(describing: error))")
      lastError = "Couldn't load conversation."
    }
  }

  // MARK: - DB plumbing (DirectMessageInboxReader pattern)

  private func ensureDatabase() throws -> LeafCore.Database {
    if let database { return database }
    let db = try LeafCore.Database.openForRead(
      at: databaseURL, config: databaseConfig, encryption: databaseEncryption
    )
    database = db
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
