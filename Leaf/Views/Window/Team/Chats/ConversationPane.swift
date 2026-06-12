//
//  ConversationPane.swift
//  Team chats — right column of the Chats tab: 1:1 thread with a
//  teammate. Header (avatar + name + role), bubble scroll (reply quotes
//  inline, Telegram-style — click a quote to jump to the original),
//  composer with reply bar + «+» menu for the structured kinds
//  (Task / Handoff open the existing SendDirectMessageSheet).
//
//  Plain chat messages ride kind `.ping` on the wire — the server CHECK
//  on direct_messages.kind allows handoff|task|ping only; a dedicated
//  `message` kind lands with the backend migration (Path B follow-up).
//
//  Inbound unread rows are marked read once the thread is on screen
//  (same 'visible long enough' semantics the feed cards use).
//

import LeafCore
import SwiftUI

struct ConversationPane: View {
  @Environment(\.aiBackendRouter) private var aiBackendRouter  // AI-UI-4
  let peer: TeamMember?
  /// Peer pubkey — non-nil even when the member left the roster (history
  /// stays readable; composer disabled in that case).
  let peerPubkeyHex: String
  let displayName: String
  let messages: [DirectMessageMirrorRow]
  let onSend: (_ body: String, _ replyTo: String?) async -> Bool
  /// Opens SendDirectMessageSheet for the structured kinds — the chosen kind
  /// pre-selects the sheet's type picker (AI-UI-3; was always .ping).
  let onComposeStructured: (TeamMember, DirectMessageKind) -> Void
  let onMarkRead: ([DirectMessageMirrorRow]) -> Void
  let onMarkDone: (DirectMessageMirrorRow) -> Void

  @State private var draft: String = ""
  @State private var replyTarget: DirectMessageMirrorRow?
  @State private var isSending = false
  @State private var jumpTarget: String?
  /// AI-UI-3 — "Context for me" sheet seed (inbound handoff bubbles).
  private struct ContextSeed: Identifiable {
    let id: String
    let row: DirectMessageMirrorRow
  }
  @State private var contextSeed: ContextSeed? = nil

  private var byID: [String: DirectMessageMirrorRow] {
    Dictionary(uniqueKeysWithValues: messages.map { ($0.messageID, $0) })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider().opacity(0.3)
      thread
      Divider().opacity(0.3)
      composer
    }
    .task(id: "\(peerPubkeyHex)-\(messages.count)") {
      let unread = messages.filter { $0.direction == .inbound && $0.readAtMs == nil }
      if !unread.isEmpty { onMarkRead(unread) }
    }
    // AI-UI-3 — recipient-side AI expansion of an inbound handoff.
    .sheet(item: $contextSeed) { seed in
      InboundHandoffContextSheet(row: seed.row, router: aiBackendRouter)
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: LeafSpace.sm) {
      Circle()
        .fill(avatarTint.gradient)
        .frame(width: LeafChatTokens.listAvatarSize, height: LeafChatTokens.listAvatarSize)
        .overlay(
          Text(TeamNRowComposer.initials(displayName))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
        )
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 0) {
        Text(displayName)
          .font(LeafType.title.small)
          .foregroundStyle(LeafColor.text.primary)
        if let peer {
          Text(peer.role == .admin ? "Admin" : "Member")
            .font(LeafType.caption)
            .foregroundStyle(LeafColor.text.tertiary)
        } else {
          Text("Former teammate")
            .font(LeafType.caption)
            .foregroundStyle(LeafColor.text.tertiary)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, LeafSpace.md)
    .padding(.vertical, LeafSpace.sm)
  }

  // MARK: - Thread

  private var thread: some View {
    ScrollViewReader { proxy in
      ScrollView(.vertical, showsIndicators: false) {
        LazyVStack(spacing: LeafChatTokens.bubbleSpacing) {
          if messages.isEmpty {
            emptyThread
          }
          ForEach(messages, id: \.messageID) { row in
            ChatBubble(
              row: row,
              quoted: row.replyTo.flatMap { byID[$0] },
              isJumpHighlight: jumpTarget == row.messageID,
              onReply: { replyTarget = row },
              onMarkDone: { onMarkDone(row) },
              onContextForMe: row.kind == .handoff && row.direction == .inbound
                ? { contextSeed = ContextSeed(id: row.messageID, row: row) } : nil,
              onJumpToQuote: { quotedID in
                withAnimation { proxy.scrollTo(quotedID, anchor: .center) }
                jumpTarget = quotedID
                Task {
                  try? await Task.sleep(nanoseconds: 1_500_000_000)
                  await MainActor.run {
                    if jumpTarget == quotedID { jumpTarget = nil }
                  }
                }
              }
            )
            .id(row.messageID)
          }
        }
        .padding(.horizontal, LeafSpace.md)
        .padding(.vertical, LeafSpace.sm)
      }
      .onChange(of: messages.count, initial: true) { _, _ in
        if let last = messages.last {
          proxy.scrollTo(last.messageID, anchor: .bottom)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var emptyThread: some View {
    VStack(spacing: LeafSpace.xs) {
      Text("No messages yet")
        .font(LeafType.body.small)
        .foregroundStyle(LeafColor.text.secondary)
      Text("Say hi — messages are end-to-end encrypted.")
        .font(LeafType.caption)
        .foregroundStyle(LeafColor.text.tertiary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, LeafSpace.xxl)
  }

  // MARK: - Composer

  private var composer: some View {
    VStack(alignment: .leading, spacing: LeafSpace.xs) {
      if let target = replyTarget {
        replyBar(target)
      }
      HStack(alignment: .bottom, spacing: LeafSpace.sm) {
        if let peer {
          Menu {
            Button("Task…") { onComposeStructured(peer, .task) }
            Button("Handoff…") { onComposeStructured(peer, .handoff) }
          } label: {
            LeafIcon(systemName: "plus.circle", size: .md, tint: LeafColor.text.secondary)
          }
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .frame(width: LeafSpace.xl)
        }
        TextField(
          peer == nil ? "Former teammate — read only" : "Message \(displayName)",
          text: $draft, axis: .vertical
        )
        .textFieldStyle(.plain)
        .font(LeafType.body.regular)
        .lineLimit(1...5)
        .disabled(peer == nil || isSending)
        .onSubmit { Task { await sendDraft() } }
        .padding(.horizontal, LeafSpace.sm)
        .padding(.vertical, LeafSpace.sm)
        .background(
          RoundedRectangle(
            cornerRadius: LeafChatTokens.composerCornerRadius, style: .continuous
          )
          .fill(LeafColor.surface.inset)
        )
        Button {
          Task { await sendDraft() }
        } label: {
          LeafIcon(
            systemName: "paperplane.fill",
            size: .md,
            tint: canSend ? LeafColor.accent.primary : LeafColor.text.quaternary
          )
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .keyboardShortcut(.return, modifiers: .command)
      }
    }
    .padding(LeafSpace.md)
  }

  private var canSend: Bool {
    peer != nil && !isSending
      && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func replyBar(_ target: DirectMessageMirrorRow) -> some View {
    HStack(spacing: LeafSpace.sm) {
      RoundedRectangle(cornerRadius: LeafChatTokens.quoteCornerRadius)
        .fill(LeafColor.accent.primary)
        .frame(width: LeafChatTokens.quoteBarWidth)
      VStack(alignment: .leading, spacing: 0) {
        Text("Replying to \(target.direction == .outbound ? "yourself" : displayName)")
          .font(LeafType.caption)
          .foregroundStyle(LeafColor.accent.emphasis)
        Text(target.body)
          .font(LeafType.caption)
          .foregroundStyle(LeafColor.text.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
      Button {
        replyTarget = nil
      } label: {
        LeafIcon(systemName: "xmark.circle.fill", size: .sm, tint: LeafColor.text.tertiary)
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, LeafSpace.sm)
    .padding(.vertical, LeafSpace.xs)
    .background(
      RoundedRectangle(cornerRadius: LeafChatTokens.quoteCornerRadius, style: .continuous)
        .fill(LeafColor.surface.inset)
    )
    .fixedSize(horizontal: false, vertical: true)
  }

  private func sendDraft() async {
    guard canSend else { return }
    let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    isSending = true
    let ok = await onSend(body, replyTarget?.messageID)
    isSending = false
    if ok {
      draft = ""
      replyTarget = nil
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
      memberID: peerPubkeyHex, paletteCount: palette.count)
    return palette[idx]
  }
}

// MARK: - Bubble

private struct ChatBubble: View {
  let row: DirectMessageMirrorRow
  let quoted: DirectMessageMirrorRow?
  let isJumpHighlight: Bool
  let onReply: () -> Void
  let onMarkDone: () -> Void
  /// AI-UI-3 — non-nil only on inbound handoff bubbles: opens "Context for me".
  let onContextForMe: (() -> Void)?
  let onJumpToQuote: (String) -> Void

  private var isOutbound: Bool { row.direction == .outbound }

  var body: some View {
    HStack(spacing: 0) {
      if isOutbound { Spacer(minLength: 0) }
      VStack(alignment: .leading, spacing: LeafSpace.xs) {
        if row.kind != .ping {
          kindLabel
        }
        if let quoted {
          quoteBlock(quoted)
        } else if let replyTo = row.replyTo {
          // Quoted message fell out of the loaded window.
          Text("Replying to an earlier message")
            .font(LeafType.caption)
            .foregroundStyle(LeafColor.text.tertiary)
            .onTapGesture { onJumpToQuote(replyTo) }
        }
        // Track C (UC-4) — structured handoff card above the text: last
        // commit / open review / status / last thread, the landing mockup.
        if row.kind == .handoff, let snapshot = row.contextSnapshot,
           snapshot.hasAnyLine {
          HandoffCardView(snapshot: snapshot, onOpenFull: onContextForMe)
        }
        Text(row.body)
          .font(LeafType.body.regular)
          .foregroundStyle(LeafColor.text.primary)
          .textSelection(.enabled)
        HStack(spacing: LeafSpace.xs) {
          Text(Self.clockTime(forMs: row.serverCreatedAtMs))
            .font(LeafType.caption)
            .foregroundStyle(LeafColor.text.quaternary)
          if isOutbound, row.readAtMs != nil {
            LeafIcon(systemName: "checkmark.circle", size: .sm, tint: LeafColor.text.quaternary)
              .help("Read")
          }
          if row.kind == .task {
            taskStateLabel
          }
          if let onContextForMe {
            Button("Context for me") { onContextForMe() }
              .buttonStyle(.plain)
              .font(LeafType.caption)
              .foregroundStyle(LeafColor.accent.emphasis)
              .help("Ask your AI what this handoff means for your own work")
          }
        }
      }
      .padding(.horizontal, LeafChatTokens.bubblePaddingH)
      .padding(.vertical, LeafChatTokens.bubblePaddingV)
      .background(
        RoundedRectangle(
          cornerRadius: LeafChatTokens.bubbleCornerRadius, style: .continuous
        )
        .fill(bubbleFill)
      )
      .overlay(
        RoundedRectangle(
          cornerRadius: LeafChatTokens.bubbleCornerRadius, style: .continuous
        )
        .strokeBorder(
          isJumpHighlight ? LeafColor.accent.primary : Color.clear)
      )
      .frame(
        maxWidth: LeafChatTokens.bubbleMaxWidth,
        alignment: isOutbound ? .trailing : .leading
      )
      .contextMenu {
        Button("Reply") { onReply() }
        Button("Copy Text") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(row.body, forType: .string)
        }
        if row.kind == .task, row.doneAtMs == nil, !isOutbound {
          Divider()
          Button("Mark Done") { onMarkDone() }
        }
        if let onContextForMe {
          Divider()
          Button("Context for me (AI)") { onContextForMe() }
        }
      }
      if !isOutbound { Spacer(minLength: 0) }
    }
  }

  private var bubbleFill: Color {
    isOutbound ? LeafColor.accent.subtle : LeafColor.surface.raised
  }

  private var kindLabel: some View {
    LeafPill(
      title: row.kind == .task ? "Task" : "Handoff",
      tone: row.kind == .task ? .warning : .accent
    )
  }

  @ViewBuilder
  private var taskStateLabel: some View {
    if row.doneAtMs != nil {
      Text("✓ Done")
        .font(LeafType.caption)
        .foregroundStyle(LeafColor.status.success)
    } else {
      Text("Open")
        .font(LeafType.caption)
        .foregroundStyle(LeafColor.text.tertiary)
    }
  }

  private func quoteBlock(_ quoted: DirectMessageMirrorRow) -> some View {
    HStack(spacing: LeafSpace.sm) {
      RoundedRectangle(cornerRadius: LeafChatTokens.quoteCornerRadius)
        .fill(LeafColor.accent.primary)
        .frame(width: LeafChatTokens.quoteBarWidth)
      Text(quoted.body)
        .font(LeafType.caption)
        .foregroundStyle(LeafColor.text.secondary)
        .lineLimit(2)
    }
    .padding(.horizontal, LeafSpace.xs)
    .padding(.vertical, LeafSpace.xxs)
    .background(
      RoundedRectangle(cornerRadius: LeafChatTokens.quoteCornerRadius, style: .continuous)
        .fill(LeafColor.surface.inset.opacity(0.6))
    )
    .contentShape(Rectangle())
    .onTapGesture { onJumpToQuote(quoted.messageID) }
    .fixedSize(horizontal: false, vertical: true)
  }

  private static func clockTime(forMs ms: Int64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    let f = DateFormatter()
    f.timeStyle = .short
    f.dateStyle = .none
    return f.string(from: date)
  }
}
