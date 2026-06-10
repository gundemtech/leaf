//
//  ChatListPresentation.swift
//  Team chats — pure presentation for the hub Chats tab conversation
//  list. Merges the workspace roster with per-peer message summaries
//  (MessagesMirrorStore.conversationSummaries) so every active teammate
//  has a chat entry even before the first message, while history with
//  former teammates stays visible (audit > соблазн — non-retroactive).
//
//  No DB access here — testable value transforms (TeamFeedPresentation
//  precedent).
//

import Foundation

/// Per-peer rollup read from messages_mirror (one row per counterpart).
public struct ChatPeerSummary: Sendable, Equatable {
  public let peerPubkeyHex: String
  public let lastBody: String
  public let lastKind: DirectMessageKind
  public let lastAtMs: Int64
  public let lastIsOutbound: Bool
  public let unreadCount: Int

  public init(
    peerPubkeyHex: String,
    lastBody: String,
    lastKind: DirectMessageKind,
    lastAtMs: Int64,
    lastIsOutbound: Bool,
    unreadCount: Int
  ) {
    self.peerPubkeyHex = peerPubkeyHex
    self.lastBody = lastBody
    self.lastKind = lastKind
    self.lastAtMs = lastAtMs
    self.lastIsOutbound = lastIsOutbound
    self.unreadCount = unreadCount
  }
}

/// One row of the conversation list. `lastAtMs == nil` → empty chat
/// (teammate without history yet).
public struct ChatConversation: Sendable, Equatable, Identifiable {
  public let peerPubkeyHex: String
  public let displayName: String
  public let lastBody: String?
  public let lastKind: DirectMessageKind?
  public let lastAtMs: Int64?
  public let lastIsOutbound: Bool
  public let unreadCount: Int

  public var id: String { peerPubkeyHex }

  public init(
    peerPubkeyHex: String,
    displayName: String,
    lastBody: String?,
    lastKind: DirectMessageKind?,
    lastAtMs: Int64?,
    lastIsOutbound: Bool,
    unreadCount: Int
  ) {
    self.peerPubkeyHex = peerPubkeyHex
    self.displayName = displayName
    self.lastBody = lastBody
    self.lastKind = lastKind
    self.lastAtMs = lastAtMs
    self.lastIsOutbound = lastIsOutbound
    self.unreadCount = unreadCount
  }

  /// Single-line list preview: kind prefix for task/handoff, "You: " for
  /// outbound, newlines collapsed. Nil when the chat has no history.
  public var previewText: String? {
    guard let body = lastBody, let kind = lastKind else { return nil }
    let flat = body
      .components(separatedBy: .newlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    let kindPrefix: String
    switch kind {
    case .task: kindPrefix = "Task: "
    case .handoff: kindPrefix = "Handoff: "
    case .ping: kindPrefix = ""
    }
    let youPrefix = lastIsOutbound ? "You: " : ""
    return youPrefix + kindPrefix + flat
  }
}

public enum ChatListPresentation {

  /// Roster ∪ summaries merge. Ordering: chats with history newest-first,
  /// then empty chats alphabetically. Self excluded. Summaries whose peer
  /// left the roster resolve to the "Former teammate" fallback.
  public static func conversations(
    members: [TeamMember],
    summaries: [ChatPeerSummary],
    selfPubkeyHex: String
  ) -> [ChatConversation] {
    let byPeer = Dictionary(
      summaries.map { ($0.peerPubkeyHex, $0) },
      uniquingKeysWith: { a, b in a.lastAtMs >= b.lastAtMs ? a : b }
    )
    let activeMembers = members.filter { $0.removedAt == nil && $0.pubkeyHex != selfPubkeyHex }
    let rosterPeers = Set(activeMembers.map(\.pubkeyHex))

    var chats: [ChatConversation] = activeMembers.map { member in
      let s = byPeer[member.pubkeyHex]
      return ChatConversation(
        peerPubkeyHex: member.pubkeyHex,
        displayName: member.displayName,
        lastBody: s?.lastBody,
        lastKind: s?.lastKind,
        lastAtMs: s?.lastAtMs,
        lastIsOutbound: s?.lastIsOutbound ?? false,
        unreadCount: s?.unreadCount ?? 0
      )
    }
    // History with peers outside the active roster (removed / former).
    for summary in summaries where !rosterPeers.contains(summary.peerPubkeyHex) {
      guard summary.peerPubkeyHex != selfPubkeyHex else { continue }
      chats.append(
        ChatConversation(
          peerPubkeyHex: summary.peerPubkeyHex,
          displayName: TeamMemberNameResolver.displayName(
            pubkeyHex: summary.peerPubkeyHex, members: members),
          lastBody: summary.lastBody,
          lastKind: summary.lastKind,
          lastAtMs: summary.lastAtMs,
          lastIsOutbound: summary.lastIsOutbound,
          unreadCount: summary.unreadCount
        ))
    }

    return chats.sorted { a, b in
      switch (a.lastAtMs, b.lastAtMs) {
      case (let x?, let y?) where x != y: return x > y
      case (.some, .none): return true
      case (.none, .some): return false
      default:
        let name = a.displayName.localizedCaseInsensitiveCompare(b.displayName)
        if name != .orderedSame { return name == .orderedAscending }
        return a.peerPubkeyHex < b.peerPubkeyHex
      }
    }
  }

  /// Case-insensitive display-name filter; blank query passes everything.
  public static func filtered(
    _ chats: [ChatConversation], query: String
  ) -> [ChatConversation] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return chats }
    return chats.filter { $0.displayName.localizedCaseInsensitiveContains(q) }
  }
}
