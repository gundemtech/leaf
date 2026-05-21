//
//  LeafWorkspaceSwitcher.swift
//  Track 5 / S7 — Organism. Sidebar bottom workspace picker. Renders one
//  row per workspace (active checkmark + avatar initials + name + unread
//  badge) plus "Add workspace" + "Join workspace" footer rows. Context menu
//  per row: "Mark all read" (when unread > 0) + "Leave Workspace"
//  (destructive).
//
//  Track 6 — `onJoin` row paired with `onAddNew` closes the UX gap where
//  already-onboarded users had no in-app entry point to join a second
//  workspace via `leaf://invite/...` link. Substrate (multi-workspace
//  table, per-workspace TeamKeystore, ActiveWorkspaceStore, switcher) has
//  been ready since Track 5 S2/S7; only the surface to AcceptInviteSheet
//  outside Onboarding was missing.
//
//  Placed in Layouts/ (Organism tier) alongside LeafNavRow, LeafCard, etc.
//

import LeafCore
import SwiftUI

struct LeafWorkspaceSwitcher: View {
  /// Caller sorts workspaces alphabetically before passing.
  let workspaces: [Workspace]
  let activeWorkspaceID: String?
  /// workspace_id → unread DM count (0 / absent = no badge).
  let unreadCounts: [String: Int]
  let onSelect: (String) -> Void
  let onAddNew: () -> Void
  /// Opens AcceptInviteSheet so the user can paste / use a
  /// `leaf://invite/...` link from another workspace's admin.
  let onJoin: () -> Void
  /// Shown in context menu — destructive.
  let onLeave: (String) -> Void
  let onMarkAllRead: (String) -> Void

  init(
    workspaces: [Workspace],
    activeWorkspaceID: String?,
    unreadCounts: [String: Int],
    onSelect: @escaping (String) -> Void,
    onAddNew: @escaping () -> Void,
    onJoin: @escaping () -> Void,
    onLeave: @escaping (String) -> Void,
    onMarkAllRead: @escaping (String) -> Void
  ) {
    self.workspaces = workspaces
    self.activeWorkspaceID = activeWorkspaceID
    self.unreadCounts = unreadCounts
    self.onSelect = onSelect
    self.onAddNew = onAddNew
    self.onJoin = onJoin
    self.onLeave = onLeave
    self.onMarkAllRead = onMarkAllRead
  }

  var body: some View {
    VStack(alignment: .leading, spacing: LeafWorkspaceSwitcherTokens.interRowSpacing) {
      ForEach(workspaces, id: \.id) { ws in
        workspaceRow(ws)
      }
      Divider().opacity(LeafWorkspaceSwitcherTokens.dividerOpacity)
      addNewRow
      joinRow
    }
    .padding(LeafWorkspaceSwitcherTokens.sectionPadding)
    .background(LeafColor.surface.inset)
  }

  // MARK: - Private helpers

  private func workspaceRow(_ ws: Workspace) -> some View {
    let isActive = ws.id == activeWorkspaceID
    let unread = unreadCounts[ws.id] ?? 0
    let isSoftLeft = ws.leftAt != nil
    return HStack(spacing: LeafSpace.sm) {
      // Leading checkmark / hollow-circle indicator
      Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
        .font(.system(size: LeafWorkspaceSwitcherTokens.activeIconSize))
        .foregroundStyle(
          isActive ? LeafColor.accent.primary : LeafColor.text.tertiary
        )
        .frame(
          width: LeafWorkspaceSwitcherTokens.activeIconSize,
          height: LeafWorkspaceSwitcherTokens.activeIconSize
        )
      // Initials avatar — clamped to avatarSize via frame clipShape
      LeafAvatar(initials: initials(for: ws.name), size: .sm)
        .frame(
          width: LeafWorkspaceSwitcherTokens.avatarSize,
          height: LeafWorkspaceSwitcherTokens.avatarSize
        )
        .clipShape(Circle())
      Text(ws.name)
        .font(isActive ? LeafType.title.small : LeafType.body.regular)
        .foregroundStyle(
          isSoftLeft ? LeafColor.text.tertiary : LeafColor.text.primary
        )
        .lineLimit(1)
      Spacer()
      if unread > 0 {
        LeafBadge(count: unread)
      }
    }
    .frame(height: LeafWorkspaceSwitcherTokens.rowHeight)
    .contentShape(.rect)
    .onTapGesture { onSelect(ws.id) }
    .contextMenu {
      if unread > 0 {
        Button("Mark all read") { onMarkAllRead(ws.id) }
        Divider()
      }
      Button("Leave Workspace", role: .destructive) { onLeave(ws.id) }
    }
  }

  // Round 8 — user feedback: footer rows now use LeafButton.secondary so
  // they read as proper buttons (matching the rest of the design system)
  // instead of bare HStack tap-targets. Full-width via .frame
  // maxWidth:.infinity + label HStack so the icon stays leading and the
  // hit area covers the whole sidebar column.
  private var addNewRow: some View {
    LeafButton(
      variant: .secondary,
      size: .sm,
      icon: .system("plus.circle"),
      action: onAddNew
    ) {
      HStack {
        Text("Add workspace")
        Spacer(minLength: 0)
      }
    }
    .frame(maxWidth: .infinity)
  }

  private var joinRow: some View {
    LeafButton(
      variant: .secondary,
      size: .sm,
      icon: .system("link.circle"),
      action: onJoin
    ) {
      HStack {
        Text("Join workspace")
        Spacer(minLength: 0)
      }
    }
    .frame(maxWidth: .infinity)
  }

  /// Derives initials from a workspace name. Multi-word names get the
  /// first letter of each of the first two words ("Leaf Backend" → "LB").
  /// Single-word names get only the FIRST letter ("test" → "T", "123" →
  /// "1") — the earlier 2-char rule produced redundant-looking rows like
  /// "TE test" / "12 123" / "45 456" when both the avatar and the inline
  /// label sat in the same line of the switcher row.
  private func initials(for name: String) -> String {
    let parts = name.split(separator: " ").map(String.init)
    if parts.count >= 2 {
      let a = parts[0].first.map(String.init) ?? ""
      let b = parts[1].first.map(String.init) ?? ""
      return (a + b).uppercased()
    }
    if let first = parts.first?.first {
      return String(first).uppercased()
    }
    return "?"
  }
}
