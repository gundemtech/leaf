//
//  ChatListPresentationTests.swift
//  LeafCoreTests
//
//  Team chats — pure presentation for the conversation list: roster ∪
//  message summaries merge, ordering, unread, preview text, search.
//

import XCTest

@testable import LeafCore

final class ChatListPresentationTests: XCTestCase {

  // MARK: - Fixtures

  private func makeMember(
    id: String = "m-1",
    pubkeyHex: String = "aa",
    displayName: String = "Alice"
  ) -> TeamMember {
    TeamMember(
      id: id,
      workspaceID: "w1",
      role: .member,
      pubkeyHex: pubkeyHex,
      displayName: displayName,
      addedAt: Date(timeIntervalSince1970: 0),
      removedAt: nil
    )
  }

  private func makeSummary(
    peer: String,
    lastBody: String = "hello",
    lastKind: DirectMessageKind = .ping,
    lastAtMs: Int64 = 1_000,
    lastIsOutbound: Bool = false,
    unread: Int = 0
  ) -> ChatPeerSummary {
    ChatPeerSummary(
      peerPubkeyHex: peer,
      lastBody: lastBody,
      lastKind: lastKind,
      lastAtMs: lastAtMs,
      lastIsOutbound: lastIsOutbound,
      unreadCount: unread
    )
  }

  // MARK: - Merge + ordering

  func testEveryActiveMemberGetsAConversationEvenWithoutHistory() {
    let members = [
      makeMember(id: "m-1", pubkeyHex: "aa", displayName: "Alice"),
      makeMember(id: "m-2", pubkeyHex: "bb", displayName: "Eve"),
    ]
    let chats = ChatListPresentation.conversations(
      members: members, summaries: [], selfPubkeyHex: "self")
    XCTAssertEqual(chats.count, 2)
    XCTAssertTrue(chats.allSatisfy { $0.lastAtMs == nil && $0.unreadCount == 0 })
  }

  func testSelfIsExcludedFromTheList() {
    let members = [
      makeMember(id: "m-1", pubkeyHex: "self", displayName: "Me"),
      makeMember(id: "m-2", pubkeyHex: "bb", displayName: "Eve"),
    ]
    let chats = ChatListPresentation.conversations(
      members: members, summaries: [], selfPubkeyHex: "self")
    XCTAssertEqual(chats.map(\.peerPubkeyHex), ["bb"])
  }

  func testConversationsWithHistorySortAboveEmptyOnesNewestFirst() {
    let members = [
      makeMember(id: "m-1", pubkeyHex: "aa", displayName: "Alice"),
      makeMember(id: "m-2", pubkeyHex: "bb", displayName: "Eve"),
      makeMember(id: "m-3", pubkeyHex: "cc", displayName: "Zoe"),
    ]
    let summaries = [
      makeSummary(peer: "cc", lastAtMs: 500),
      makeSummary(peer: "bb", lastAtMs: 900),
    ]
    let chats = ChatListPresentation.conversations(
      members: members, summaries: summaries, selfPubkeyHex: "self")
    XCTAssertEqual(chats.map(\.peerPubkeyHex), ["bb", "cc", "aa"])
  }

  func testEmptyConversationsSortAlphabetically() {
    let members = [
      makeMember(id: "m-1", pubkeyHex: "aa", displayName: "zoe"),
      makeMember(id: "m-2", pubkeyHex: "bb", displayName: "Alice"),
    ]
    let chats = ChatListPresentation.conversations(
      members: members, summaries: [], selfPubkeyHex: "self")
    XCTAssertEqual(chats.map(\.displayName), ["Alice", "zoe"])
  }

  func testSummaryFromFormerTeammateStillListedWithResolvedFallbackName() {
    // Message history from a peer no longer in the roster (removed member):
    // the conversation must stay visible (audit > соблазн), name falls back.
    let members = [makeMember(id: "m-1", pubkeyHex: "aa", displayName: "Alice")]
    let summaries = [makeSummary(peer: "gone", lastAtMs: 700, unread: 2)]
    let chats = ChatListPresentation.conversations(
      members: members, summaries: summaries, selfPubkeyHex: "self")
    XCTAssertEqual(chats.first?.peerPubkeyHex, "gone")
    XCTAssertEqual(chats.first?.displayName, "Former teammate")
    XCTAssertEqual(chats.first?.unreadCount, 2)
  }

  // MARK: - Preview text

  func testPreviewTextPlainForPing() {
    let chat = ChatConversation(
      peerPubkeyHex: "aa", displayName: "Alice",
      lastBody: "see you at standup", lastKind: .ping, lastAtMs: 1,
      lastIsOutbound: false, unreadCount: 0)
    XCTAssertEqual(chat.previewText, "see you at standup")
  }

  func testPreviewTextPrefixesKindForTaskAndHandoff() {
    let task = ChatConversation(
      peerPubkeyHex: "aa", displayName: "Alice",
      lastBody: "fix the build", lastKind: .task, lastAtMs: 1,
      lastIsOutbound: false, unreadCount: 0)
    XCTAssertEqual(task.previewText, "Task: fix the build")
    let handoff = ChatConversation(
      peerPubkeyHex: "aa", displayName: "Alice",
      lastBody: "branch is yours", lastKind: .handoff, lastAtMs: 1,
      lastIsOutbound: false, unreadCount: 0)
    XCTAssertEqual(handoff.previewText, "Handoff: branch is yours")
  }

  func testPreviewTextMarksOutboundWithYouPrefix() {
    let chat = ChatConversation(
      peerPubkeyHex: "aa", displayName: "Alice",
      lastBody: "ok", lastKind: .ping, lastAtMs: 1,
      lastIsOutbound: true, unreadCount: 0)
    XCTAssertEqual(chat.previewText, "You: ok")
  }

  func testPreviewTextCollapsesNewlines() {
    let chat = ChatConversation(
      peerPubkeyHex: "aa", displayName: "Alice",
      lastBody: "line one\nline two", lastKind: .ping, lastAtMs: 1,
      lastIsOutbound: false, unreadCount: 0)
    XCTAssertEqual(chat.previewText, "line one line two")
  }

  func testPreviewTextNilForEmptyConversation() {
    let chat = ChatConversation(
      peerPubkeyHex: "aa", displayName: "Alice",
      lastBody: nil, lastKind: nil, lastAtMs: nil,
      lastIsOutbound: false, unreadCount: 0)
    XCTAssertNil(chat.previewText)
  }

  // MARK: - Search

  func testSearchFiltersByDisplayNameCaseInsensitive() {
    let members = [
      makeMember(id: "m-1", pubkeyHex: "aa", displayName: "Alice"),
      makeMember(id: "m-2", pubkeyHex: "bb", displayName: "Eve"),
    ]
    let chats = ChatListPresentation.conversations(
      members: members, summaries: [], selfPubkeyHex: "self")
    XCTAssertEqual(
      ChatListPresentation.filtered(chats, query: "ali").map(\.displayName), ["Alice"])
    XCTAssertEqual(ChatListPresentation.filtered(chats, query: "  ").count, 2)
    XCTAssertEqual(ChatListPresentation.filtered(chats, query: "zzz").count, 0)
  }
}
