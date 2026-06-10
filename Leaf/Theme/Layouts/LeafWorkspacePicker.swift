//
//  LeafWorkspacePicker.swift
//  Organism. Sidebar bottom workspace picker: one compact trigger row
//  (active-workspace avatar + name + aggregate unread badge + chevron)
//  opening a popover with the full workspace list and Add / Join footer.
//
//  Replaces LeafWorkspaceSwitcher (Track 5 / S7) — the inline flat list
//  ate half the sidebar once a user joined more than a few workspaces.
//  Same callback API, so Sidebar wiring is unchanged. Popover row visuals
//  (checkmark indicator + initials avatar + unread badge + context menu
//  Mark all read / Leave) carry over from the switcher rows.
//
//  Trigger badge counts unread in NON-active workspaces only — the active
//  workspace's unread is already visible in Team; the trigger signals
//  "something waits elsewhere".
//

import LeafCore
import SwiftUI

struct LeafWorkspacePicker: View {
  /// Caller sorts workspaces alphabetically before passing.
  let workspaces: [Workspace]
  let activeWorkspaceID: String?
  /// workspace_id → unread DM count (0 / absent = no badge).
  let unreadCounts: [String: Int]
  let onSelect: (String) -> Void
  let onAddNew: () -> Void
  /// Opens JoinWorkspaceByCodeSheet so the user can paste an invite code.
  let onJoin: () -> Void
  /// Shown in row context menu — destructive.
  let onLeave: (String) -> Void
  let onMarkAllRead: (String) -> Void

  @State private var popoverPresented = false
  @State private var hover = false

  var body: some View {
    Button {
      popoverPresented.toggle()
    } label: {
      triggerLabel
    }
    .buttonStyle(.plain)
    .onHover { hover = $0 }
    .leafAnimation(LeafMotion.spring.snappy, value: hover)
    .popover(isPresented: $popoverPresented, arrowEdge: .top) {
      LeafWorkspacePickerList(
        workspaces: workspaces,
        activeWorkspaceID: activeWorkspaceID,
        unreadCounts: unreadCounts,
        onSelect: { wid in
          popoverPresented = false
          onSelect(wid)
        },
        onAddNew: {
          popoverPresented = false
          onAddNew()
        },
        onJoin: {
          popoverPresented = false
          onJoin()
        },
        onLeave: { wid in
          popoverPresented = false
          onLeave(wid)
        },
        onMarkAllRead: onMarkAllRead
      )
    }
    .padding(LeafWorkspacePickerTokens.sectionPadding)
    .background(LeafColor.surface.inset)
  }

  // MARK: - Trigger row

  private var triggerLabel: some View {
    HStack(spacing: LeafSpace.sm) {
      if workspaces.isEmpty {
        LeafIcon(systemName: "plus.circle", size: .md, tint: LeafColor.text.secondary)
        Text("Add workspace")
          .font(LeafType.body.regular)
          .foregroundStyle(LeafColor.text.primary)
      } else if let active = activeWorkspace {
        LeafAvatar(initials: workspaceInitials(for: active.name), size: .sm)
          .frame(
            width: LeafWorkspacePickerTokens.avatarSize,
            height: LeafWorkspacePickerTokens.avatarSize
          )
          .clipShape(Circle())
        Text(active.name)
          .font(LeafType.title.small)
          .foregroundStyle(LeafColor.text.primary)
          .lineLimit(1)
      } else {
        Text("Select workspace")
          .font(LeafType.body.regular)
          .foregroundStyle(LeafColor.text.secondary)
      }
      Spacer(minLength: 0)
      if inactiveUnread > 0 {
        LeafBadge(count: inactiveUnread)
      }
      Image(systemName: "chevron.up.chevron.down")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(LeafColor.text.tertiary)
    }
    .padding(.horizontal, LeafSpace.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(height: LeafWorkspacePickerTokens.triggerHeight)
    .background(
      RoundedRectangle(
        cornerRadius: LeafWorkspacePickerTokens.triggerCornerRadius,
        style: .continuous
      )
      .fill(hover ? LeafColor.surface.raised : Color.clear)
    )
    .contentShape(Rectangle())
  }

  private var activeWorkspace: Workspace? {
    workspaces.first { $0.id == activeWorkspaceID }
  }

  private var inactiveUnread: Int {
    workspaces
      .filter { $0.id != activeWorkspaceID }
      .reduce(0) { $0 + (unreadCounts[$1.id] ?? 0) }
  }
}

// MARK: - Popover list

/// Popover content — internal so LeafWorkspacePickerPreview can render it
/// inline (a statically-open popover can't be captured in TokensPreview).
struct LeafWorkspacePickerList: View {
  let workspaces: [Workspace]
  let activeWorkspaceID: String?
  let unreadCounts: [String: Int]
  let onSelect: (String) -> Void
  let onAddNew: () -> Void
  let onJoin: () -> Void
  let onLeave: (String) -> Void
  let onMarkAllRead: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: LeafWorkspacePickerTokens.interRowSpacing) {
      if !workspaces.isEmpty {
        Text("WORKSPACES")
          .leafSectionLabel()
          .foregroundStyle(LeafColor.text.tertiary)
        ScrollView(.vertical, showsIndicators: false) {
          VStack(alignment: .leading, spacing: LeafWorkspacePickerTokens.interRowSpacing) {
            ForEach(workspaces, id: \.id) { ws in
              PickerRow(
                workspace: ws,
                isActive: ws.id == activeWorkspaceID,
                unread: unreadCounts[ws.id] ?? 0,
                onSelect: onSelect,
                onLeave: onLeave,
                onMarkAllRead: onMarkAllRead
              )
            }
          }
        }
        .frame(maxHeight: listHeight)
        Divider().opacity(LeafWorkspacePickerTokens.dividerOpacity)
      }
      addNewRow
      joinRow
    }
    .padding(LeafWorkspacePickerTokens.sectionPadding)
    .frame(width: LeafWorkspacePickerTokens.popoverWidth)
  }

  /// Hug content below the cap — a bare `.frame(maxHeight:)` would make
  /// the greedy ScrollView always occupy the full cap height.
  private var listHeight: CGFloat {
    let rows = CGFloat(workspaces.count)
    let content =
      rows * LeafWorkspacePickerTokens.rowHeight
      + max(rows - 1, 0) * LeafWorkspacePickerTokens.interRowSpacing
    return min(content, LeafWorkspacePickerTokens.maxListHeight)
  }

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
}

/// One workspace row inside the popover — own struct so each row carries
/// its own hover state.
private struct PickerRow: View {
  let workspace: Workspace
  let isActive: Bool
  let unread: Int
  let onSelect: (String) -> Void
  let onLeave: (String) -> Void
  let onMarkAllRead: (String) -> Void

  @State private var hover = false

  var body: some View {
    let isSoftLeft = workspace.leftAt != nil
    HStack(spacing: LeafSpace.sm) {
      Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
        .font(.system(size: LeafWorkspacePickerTokens.activeIconSize))
        .foregroundStyle(
          isActive ? LeafColor.accent.primary : LeafColor.text.tertiary
        )
        .frame(
          width: LeafWorkspacePickerTokens.activeIconSize,
          height: LeafWorkspacePickerTokens.activeIconSize
        )
      LeafAvatar(initials: workspaceInitials(for: workspace.name), size: .sm)
        .frame(
          width: LeafWorkspacePickerTokens.avatarSize,
          height: LeafWorkspacePickerTokens.avatarSize
        )
        .clipShape(Circle())
      Text(workspace.name)
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
    .padding(.horizontal, LeafSpace.xs)
    .frame(height: LeafWorkspacePickerTokens.rowHeight)
    .background(
      RoundedRectangle(cornerRadius: LeafRadius.sm, style: .continuous)
        .fill(hover ? LeafColor.surface.raised : Color.clear)
    )
    .contentShape(.rect)
    .onTapGesture { onSelect(workspace.id) }
    .onHover { hover = $0 }
    .contextMenu {
      if unread > 0 {
        Button("Mark all read") { onMarkAllRead(workspace.id) }
        Divider()
      }
      Button("Leave Workspace", role: .destructive) { onLeave(workspace.id) }
    }
  }
}

/// Derives initials from a workspace name. Multi-word names get the
/// first letter of each of the first two words ("Leaf Backend" → "LB").
/// Single-word names get only the FIRST letter ("test" → "T") — a 2-char
/// rule produced redundant-looking rows like "TE test" when the avatar
/// and the inline label sit on the same line.
private func workspaceInitials(for name: String) -> String {
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
