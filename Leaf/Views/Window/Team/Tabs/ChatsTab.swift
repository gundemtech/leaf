//
//  ChatsTab.swift
//  Team chats — the hub Chats tab: two-pane chat manager. Left —
//  conversation list (search + Activity pseudo-chat + one row per
//  teammate, ChatStore). Right — selected 1:1 thread (ConversationPane)
//  or the ambient team feed (TeamFeedTab) when Activity is selected.
//
//  Real messaging on the existing substrate: composer sends through
//  DirectMessageSendReader (kind .ping until the backend gains a
//  dedicated `message` kind — direct_messages.kind CHECK, Path B),
//  replies use the wired `replyTo`, inbound updates arrive through
//  DirectMessageInboxReader (polling tick + Realtime absorb) whose
//  `recentMessages` republish drives ChatStore.refresh.
//

import LeafCore
import SwiftUI

struct ChatsTab: View {
  let active: Workspace
  let members: [TeamMember]
  let selfPubkeyHex: () -> String
  let onInvite: () -> Void
  /// Routes to SendDirectMessageSheet (structured Task / Handoff sends +
  /// the feed empty-state CTA semantics).
  let onSendDM: (TeamMember?) -> Void

  @Environment(ChatStore.self) private var chatStore
  @Environment(DirectMessageInboxReader.self) private var inboxReader
  @Environment(DirectMessageSendReader.self) private var sendReader

  var body: some View {
    HStack(alignment: .top, spacing: LeafSpace.md) {
      ConversationListPane(
        conversations: chatStore.conversations,
        selectedPeer: chatStore.selectedPeer,
        onSelectActivity: { chatStore.select(peer: nil, workspaceID: active.id) },
        onSelectPeer: { chatStore.select(peer: $0, workspaceID: active.id) },
        onInvite: onInvite
      )
      Divider().opacity(0.3)
      detail
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    // Workspace switch / tab mount — rebuild list, drop cross-workspace
    // selection.
    .task(id: active.id) {
      chatStore.resetSelection()
      refreshStore()
    }
    // Polling tick / Realtime absorb / markRead all republish
    // recentMessages — cheap local re-read keeps list + thread live.
    .onChange(of: inboxReader.recentMessages) { _, _ in
      refreshStore()
    }
  }

  @ViewBuilder
  private var detail: some View {
    if let peer = chatStore.selectedPeer {
      ConversationPane(
        peer: members.first { $0.pubkeyHex == peer && $0.removedAt == nil },
        peerPubkeyHex: peer,
        displayName: TeamMemberNameResolver.displayName(pubkeyHex: peer, members: members),
        messages: chatStore.messages,
        onSend: { body, replyTo in await send(to: peer, body: body, replyTo: replyTo) },
        onComposeStructured: { member in onSendDM(member) },
        onMarkRead: { rows in
          Task {
            for row in rows {
              await inboxReader.markRead(messageID: row.messageID)
            }
          }
        },
        onMarkDone: { row in
          Task { await inboxReader.markDone(messageID: row.messageID) }
        }
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      // Activity pseudo-chat — the ambient team feed, unchanged.
      VStack(alignment: .leading, spacing: LeafSpace.md) {
        TeamFeedTab(
          active: active,
          members: members,
          selfPubkeyHex: selfPubkeyHex,
          onInvite: onInvite,
          onSendDM: onSendDM
        )
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }

  private func refreshStore() {
    chatStore.refresh(
      workspaceID: active.id, members: members, selfPubkeyHex: selfPubkeyHex())
  }

  /// Composer send: kind .ping (see header), notify ON, optional replyTo.
  /// Returns success so the composer knows whether to clear the draft.
  private func send(to peer: String, body: String, replyTo: String?) async -> Bool {
    let member = members.first { $0.pubkeyHex == peer }
    await sendReader.send(
      recipientPubkeyHex: peer,
      recipientMemberID: member?.id,
      kind: .ping,
      body: body,
      notify: true,
      replyTo: replyTo
    )
    let succeeded: Bool
    switch sendReader.state {
    case .sent:
      succeeded = true
    case .error, .idle, .sending:
      succeeded = false
    }
    // Reset the shared state machine so SendDirectMessageSheet (same
    // reader instance) never opens onto a stale .sent/.error from the
    // composer path.
    sendReader.reset()
    refreshStore()
    return succeeded
  }
}
