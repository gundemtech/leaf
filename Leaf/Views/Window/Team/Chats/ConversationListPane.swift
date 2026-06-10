//
//  ConversationListPane.swift
//  Team chats — left column of the Chats tab: search field, the Activity
//  pseudo-chat (ambient team feed), and one row per teammate (roster ∪
//  message history — ChatListPresentation). Every active member has a
//  chat entry, so "new chat" = just click a teammate.
//

import LeafCore
import SwiftUI

struct ConversationListPane: View {
  let conversations: [ChatConversation]
  /// Nil = Activity pseudo-chat selected.
  let selectedPeer: String?
  let onSelectActivity: () -> Void
  let onSelectPeer: (String) -> Void
  let onInvite: () -> Void

  @State private var query: String = ""

  private var filtered: [ChatConversation] {
    ChatListPresentation.filtered(conversations, query: query)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: LeafSpace.sm) {
      searchField
      ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: LeafSpace.xxs) {
          activityRow
          if conversations.isEmpty {
            emptyRoster
          } else {
            ForEach(filtered) { chat in
              ConversationRow(
                chat: chat,
                isSelected: chat.peerPubkeyHex == selectedPeer,
                onTap: { onSelectPeer(chat.peerPubkeyHex) }
              )
            }
          }
        }
      }
    }
    .frame(width: LeafChatTokens.listWidth)
  }

  private var searchField: some View {
    HStack(spacing: LeafSpace.xs) {
      LeafIcon(systemName: "magnifyingglass", size: .sm, tint: LeafColor.text.tertiary)
      TextField("Search", text: $query)
        .textFieldStyle(.plain)
        .font(LeafType.body.small)
    }
    .padding(.horizontal, LeafSpace.sm)
    .frame(height: LeafChatTokens.composerMinHeight - LeafSpace.xs)
    .background(
      RoundedRectangle(cornerRadius: LeafChatTokens.rowCornerRadius, style: .continuous)
        .fill(LeafColor.surface.inset)
    )
  }

  private var activityRow: some View {
    ChatListRowChrome(isSelected: selectedPeer == nil, onTap: onSelectActivity) {
      HStack(spacing: LeafSpace.sm) {
        RoundedRectangle(
          cornerRadius: LeafChatTokens.rowCornerRadius, style: .continuous
        )
        .fill(LeafColor.accent.subtle)
        .frame(width: LeafChatTokens.listAvatarSize, height: LeafChatTokens.listAvatarSize)
        .overlay(
          LeafIcon(systemName: "bolt.fill", size: .sm, tint: LeafColor.accent.primary)
        )
        VStack(alignment: .leading, spacing: 0) {
          Text("Activity")
            .font(LeafType.body.regular)
            .foregroundStyle(LeafColor.text.primary)
          Text("Team events & shared work")
            .font(LeafType.caption)
            .foregroundStyle(LeafColor.text.tertiary)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
      }
    }
  }

  private var emptyRoster: some View {
    VStack(alignment: .leading, spacing: LeafSpace.sm) {
      Text("No teammates yet")
        .font(LeafType.body.small)
        .foregroundStyle(LeafColor.text.secondary)
      LeafButton("+ Invite teammate", variant: .secondary, size: .sm) {
        onInvite()
      }
    }
    .padding(LeafSpace.sm)
  }
}

// MARK: - Row

private struct ConversationRow: View {
  let chat: ChatConversation
  let isSelected: Bool
  let onTap: () -> Void

  var body: some View {
    ChatListRowChrome(isSelected: isSelected, onTap: onTap) {
      HStack(spacing: LeafSpace.sm) {
        Circle()
          .fill(avatarTint.gradient)
          .frame(
            width: LeafChatTokens.listAvatarSize, height: LeafChatTokens.listAvatarSize
          )
          .overlay(
            Text(TeamNRowComposer.initials(chat.displayName))
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(.white)
          )
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 0) {
          HStack(spacing: LeafSpace.xs) {
            Text(chat.displayName)
              .font(LeafType.body.regular)
              .foregroundStyle(LeafColor.text.primary)
              .lineLimit(1)
            Spacer(minLength: 0)
            if let ms = chat.lastAtMs {
              Text(Self.shortTime(forMs: ms))
                .font(LeafType.caption)
                .foregroundStyle(LeafColor.text.quaternary)
            }
          }
          HStack(spacing: LeafSpace.xs) {
            Text(chat.previewText ?? "No messages yet")
              .font(LeafType.caption)
              .foregroundStyle(LeafColor.text.tertiary)
              .lineLimit(1)
            Spacer(minLength: 0)
            if chat.unreadCount > 0 {
              LeafBadge(count: chat.unreadCount)
            }
          }
        }
      }
    }
  }

  private var avatarTint: Color {
    let palette: [Color] = [
      LeafColor.accent.primary,
      LeafColor.accent.emphasis,
      LeafColor.status.info,
      LeafColor.status.danger,
      LeafColor.status.warning,
    ]
    let idx = TeamNRowComposer.paletteIndex(
      memberID: chat.peerPubkeyHex, paletteCount: palette.count)
    return palette[idx]
  }

  private static func shortTime(forMs ms: Int64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f.localizedString(for: date, relativeTo: Date())
  }
}

// MARK: - Row chrome

/// Shared hover/selection chrome for list rows.
private struct ChatListRowChrome<Content: View>: View {
  let isSelected: Bool
  let onTap: () -> Void
  @ViewBuilder let content: () -> Content

  @State private var hover = false

  var body: some View {
    Button(action: onTap) {
      content()
        .padding(.horizontal, LeafSpace.sm)
        .frame(height: LeafChatTokens.listRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(
            cornerRadius: LeafChatTokens.rowCornerRadius, style: .continuous
          )
          .fill(rowFill)
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hover = $0 }
    .leafAnimation(LeafMotion.spring.snappy, value: hover)
  }

  private var rowFill: Color {
    if isSelected { return LeafColor.accent.subtle }
    if hover { return LeafColor.surface.raised }
    return Color.clear
  }
}
