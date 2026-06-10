//
//  LeafWorkspacePicker.swift
//  Organism. Workspace picker trigger row for the sidebar bottom card:
//  colored square workspace mark + active-workspace name + aggregate
//  unread badge + chevron, opening a popover with the full workspace
//  list and Add / Join footer. The bottom card itself (picker row +
//  divider + profile row) is composed in Sidebar — profile navigation
//  is app-level concern, not a theme organism.
//
//  Replaces LeafWorkspaceSwitcher (Track 5 / S7) — the inline flat list
//  ate half the sidebar once a user joined more than a few workspaces.
//  Same callback API, so Sidebar wiring is unchanged.
//
//  Trigger badge counts unread in NON-active workspaces only — the active
//  workspace's unread is already visible in Team; the trigger signals
//  "something waits elsewhere".
//
//  Workspace marks are rounded SQUARES (vs circles for people — same
//  team-vs-person distinction Slack draws), tinted deterministically per
//  workspace id via the TeamNBlock avatar palette pattern.
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
        LeafWorkspaceMark(
          name: active.name,
          seed: active.id,
          size: LeafWorkspacePickerTokens.triggerMarkSize
        )
        VStack(alignment: .leading, spacing: 0) {
          Text(active.name)
            .font(LeafType.body.regular)
            .foregroundStyle(LeafColor.text.primary)
            .lineLimit(1)
          if workspaces.count > 1 {
            Text("\(workspaces.count) workspaces")
              .font(LeafType.caption)
              .foregroundStyle(LeafColor.text.tertiary)
          }
        }
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
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(LeafColor.text.tertiary)
    }
    .padding(.horizontal, LeafSpace.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(height: LeafWorkspacePickerTokens.triggerHeight)
    .background(
      RoundedRectangle(
        cornerRadius: LeafWorkspacePickerTokens.rowCornerRadius,
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
        Text("Workspaces")
          .leafSectionLabel()
          .foregroundStyle(LeafColor.text.tertiary)
          .padding(.horizontal, LeafSpace.sm)
          .padding(.top, LeafSpace.xs)
          .padding(.bottom, LeafSpace.xxs)
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
        Divider()
          .opacity(LeafWorkspacePickerTokens.dividerOpacity)
          .padding(.vertical, LeafSpace.xxs)
      }
      FooterRow(icon: "plus.circle", title: "Add workspace", action: onAddNew)
      FooterRow(icon: "link.circle", title: "Join workspace", action: onJoin)
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
}

/// One workspace row inside the popover — own struct so each row carries
/// its own hover state. Active row gets accent.subtle fill + trailing
/// checkmark (the colored mark stays the leading anchor on every row).
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
      LeafWorkspaceMark(
        name: workspace.name,
        seed: workspace.id,
        size: LeafWorkspacePickerTokens.markSize
      )
      .opacity(isSoftLeft ? 0.5 : 1)
      Text(workspace.name)
        .font(LeafType.body.regular)
        .foregroundStyle(
          isSoftLeft ? LeafColor.text.tertiary : LeafColor.text.primary
        )
        .lineLimit(1)
      Spacer()
      if unread > 0 {
        LeafBadge(count: unread)
      }
      if isActive {
        Image(systemName: "checkmark")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(LeafColor.accent.primary)
      }
    }
    .padding(.horizontal, LeafSpace.sm)
    .frame(height: LeafWorkspacePickerTokens.rowHeight)
    .background(
      RoundedRectangle(
        cornerRadius: LeafWorkspacePickerTokens.rowCornerRadius,
        style: .continuous
      )
      .fill(rowFill)
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

  private var rowFill: Color {
    if isActive { return LeafColor.accent.subtle }
    if hover { return LeafColor.surface.raised }
    return Color.clear
  }
}

/// Footer action row — menu-item style (icon + label + hover fill)
/// instead of a boxed button, so the popover reads as one coherent menu.
private struct FooterRow: View {
  let icon: String
  let title: String
  let action: () -> Void

  @State private var hover = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: LeafSpace.sm) {
        LeafIcon(
          systemName: icon,
          size: .sm,
          tint: hover ? LeafColor.text.primary : LeafColor.text.secondary
        )
        Text(title)
          .font(LeafType.body.regular)
          .foregroundStyle(hover ? LeafColor.text.primary : LeafColor.text.secondary)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, LeafSpace.sm)
      .frame(height: LeafWorkspacePickerTokens.rowHeight)
      .background(
        RoundedRectangle(
          cornerRadius: LeafWorkspacePickerTokens.rowCornerRadius,
          style: .continuous
        )
        .fill(hover ? LeafColor.surface.raised : Color.clear)
      )
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .onHover { hover = $0 }
  }
}

// MARK: - Workspace mark

/// Rounded-square workspace identity mark: deterministic tint per `seed`
/// (workspace id) over the TeamNBlock avatar palette, initials on top.
/// Square = team, circle = person — keeps the two distinguishable at a
/// glance anywhere both appear.
struct LeafWorkspaceMark: View {
  let name: String
  let seed: String
  let size: CGFloat

  var body: some View {
    RoundedRectangle(
      cornerRadius: LeafWorkspacePickerTokens.markCornerRadius,
      style: .continuous
    )
    .fill(tint.gradient)
    .frame(width: size, height: size)
    .overlay(
      Text(workspaceInitials(for: name))
        .font(.system(size: size * 0.45, weight: .semibold))
        .foregroundStyle(.white)
    )
    .accessibilityHidden(true)
  }

  private var tint: Color {
    let palette: [Color] = [
      LeafColor.accent.primary,
      LeafColor.accent.emphasis,
      LeafColor.status.info,
      LeafColor.status.danger,
      LeafColor.status.warning,
    ]
    let idx = TeamNRowComposer.paletteIndex(memberID: seed, paletteCount: palette.count)
    return palette[idx]
  }
}

/// Derives initials from a workspace name. Multi-word names get the
/// first letter of each of the first two words ("Leaf Backend" → "LB").
/// Single-word names get only the FIRST letter ("test" → "T") — a 2-char
/// rule produced redundant-looking rows like "TE test" when the mark
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
