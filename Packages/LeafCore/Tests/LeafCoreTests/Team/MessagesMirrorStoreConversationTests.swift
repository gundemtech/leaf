//
//  MessagesMirrorStoreConversationTests.swift
//  LeafCoreTests
//
//  Team chats — per-peer conversation queries on messages_mirror:
//  readConversation (both directions with one peer, ascending) and
//  conversationSummaries (last message + unread count per peer).
//

import GRDB
import XCTest

@testable import LeafCore

final class MessagesMirrorStoreConversationTests: XCTestCase {
  private var tempDir: URL!
  private var db: LeafCore.Database!

  override func setUp() async throws {
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("leaf-chatstore-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    db = try Database.openForWrite(
      at: tempDir.appendingPathComponent("events.sqlite"),
      config: .weakDefaults,
      encryption: .deterministicTest
    )
  }

  override func tearDown() async throws {
    db = nil
    try? FileManager.default.removeItem(at: tempDir)
  }

  /// Inbound = peer → self (sender = peer); outbound = self → peer
  /// (recipient = peer). `self` pubkey never appears explicitly in rows —
  /// direction + counterpart column carry it, mirroring production writes.
  private func makeRow(
    messageID: String,
    workspaceID: String = "w1",
    peer: String,
    direction: DirectMessageMirrorRow.Direction,
    body: String = "hello",
    serverCreatedAtMs: Int64,
    readAtMs: Int64? = nil
  ) -> DirectMessageMirrorRow {
    DirectMessageMirrorRow(
      messageID: messageID,
      workspaceID: workspaceID,
      senderPubkeyHex: direction == .inbound ? peer : "selfpub",
      senderMemberID: "m-x",
      senderDisplayName: "Sender",
      recipientPubkeyHex: direction == .inbound ? "selfpub" : peer,
      kind: .ping,
      body: body,
      attachment: nil,
      replyTo: nil,
      sentAtMs: serverCreatedAtMs - 50,
      serverCreatedAtMs: serverCreatedAtMs,
      readAtMs: readAtMs,
      doneAtMs: nil,
      doneByPubkeyHex: nil,
      direction: direction,
      lastSyncedAtMs: serverCreatedAtMs
    )
  }

  private func insert(_ rows: [DirectMessageMirrorRow]) throws {
    try db.writeSQL { rawDB in
      for row in rows {
        try MessagesMirrorStore.upsert(row, in: rawDB)
      }
    }
  }

  // MARK: - readConversation

  func testReadConversationReturnsBothDirectionsForPeerAscending() throws {
    try insert([
      makeRow(messageID: "m1", peer: "anna", direction: .inbound, serverCreatedAtMs: 100),
      makeRow(messageID: "m2", peer: "anna", direction: .outbound, serverCreatedAtMs: 200),
      makeRow(messageID: "m3", peer: "alex", direction: .inbound, serverCreatedAtMs: 150),
      makeRow(messageID: "m4", peer: "anna", direction: .inbound, serverCreatedAtMs: 300),
    ])
    let convo = try db.readSQL {
      try MessagesMirrorStore.readConversation(
        workspaceID: "w1", peerPubkeyHex: "anna", limit: 50, in: $0)
    }
    XCTAssertEqual(convo.map(\.messageID), ["m1", "m2", "m4"])
  }

  func testReadConversationLimitKeepsLatestRows() throws {
    try insert(
      (1...5).map {
        makeRow(
          messageID: "m\($0)", peer: "anna", direction: .inbound,
          serverCreatedAtMs: Int64($0 * 100))
      })
    let convo = try db.readSQL {
      try MessagesMirrorStore.readConversation(
        workspaceID: "w1", peerPubkeyHex: "anna", limit: 2, in: $0)
    }
    // Latest two, still ascending for chat rendering.
    XCTAssertEqual(convo.map(\.messageID), ["m4", "m5"])
  }

  func testReadConversationScopedToWorkspace() throws {
    try insert([
      makeRow(messageID: "m1", peer: "anna", direction: .inbound, serverCreatedAtMs: 100),
      makeRow(
        messageID: "m2", workspaceID: "w2", peer: "anna", direction: .inbound,
        serverCreatedAtMs: 200),
    ])
    let convo = try db.readSQL {
      try MessagesMirrorStore.readConversation(
        workspaceID: "w1", peerPubkeyHex: "anna", limit: 50, in: $0)
    }
    XCTAssertEqual(convo.map(\.messageID), ["m1"])
  }

  // MARK: - conversationSummaries

  func testSummariesLastMessagePerPeerWithUnreadCounts() throws {
    try insert([
      makeRow(messageID: "m1", peer: "anna", direction: .inbound, serverCreatedAtMs: 100),
      makeRow(
        messageID: "m2", peer: "anna", direction: .outbound, body: "latest to anna",
        serverCreatedAtMs: 400),
      makeRow(messageID: "m3", peer: "alex", direction: .inbound, serverCreatedAtMs: 200),
      makeRow(
        messageID: "m4", peer: "alex", direction: .inbound, body: "latest from alex",
        serverCreatedAtMs: 300),
      // read inbound — must not count as unread
      makeRow(
        messageID: "m5", peer: "alex", direction: .inbound, serverCreatedAtMs: 250,
        readAtMs: 260),
    ])
    let summaries = try db.readSQL {
      try MessagesMirrorStore.conversationSummaries(workspaceID: "w1", in: $0)
    }
    let byPeer = Dictionary(uniqueKeysWithValues: summaries.map { ($0.peerPubkeyHex, $0) })
    XCTAssertEqual(byPeer["anna"]?.lastBody, "latest to anna")
    XCTAssertEqual(byPeer["anna"]?.lastIsOutbound, true)
    XCTAssertEqual(byPeer["anna"]?.unreadCount, 1)
    XCTAssertEqual(byPeer["alex"]?.lastBody, "latest from alex")
    XCTAssertEqual(byPeer["alex"]?.lastIsOutbound, false)
    XCTAssertEqual(byPeer["alex"]?.unreadCount, 2)
  }

  func testSummariesEmptyTableReturnsEmpty() throws {
    let summaries = try db.readSQL {
      try MessagesMirrorStore.conversationSummaries(workspaceID: "w1", in: $0)
    }
    XCTAssertTrue(summaries.isEmpty)
  }
}
