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

import SwiftUI
import LeafCore

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

    private var addNewRow: some View {
        HStack(spacing: LeafSpace.sm) {
            Image(systemName: "plus.circle")
                .font(.system(size: LeafWorkspaceSwitcherTokens.activeIconSize))
                .foregroundStyle(LeafColor.text.secondary)
                .frame(
                    width: LeafWorkspaceSwitcherTokens.activeIconSize,
                    height: LeafWorkspaceSwitcherTokens.activeIconSize
                )
            Text("Add workspace")
                .font(LeafType.body.regular)
                .foregroundStyle(LeafColor.text.secondary)
            Spacer()
        }
        .frame(height: LeafWorkspaceSwitcherTokens.rowHeight)
        .contentShape(.rect)
        .onTapGesture(perform: onAddNew)
    }

    private var joinRow: some View {
        HStack(spacing: LeafSpace.sm) {
            Image(systemName: "link.circle")
                .font(.system(size: LeafWorkspaceSwitcherTokens.activeIconSize))
                .foregroundStyle(LeafColor.text.secondary)
                .frame(
                    width: LeafWorkspaceSwitcherTokens.activeIconSize,
                    height: LeafWorkspaceSwitcherTokens.activeIconSize
                )
            Text("Join workspace")
                .font(LeafType.body.regular)
                .foregroundStyle(LeafColor.text.secondary)
            Spacer()
        }
        .frame(height: LeafWorkspaceSwitcherTokens.rowHeight)
        .contentShape(.rect)
        .onTapGesture(perform: onJoin)
    }

    /// Derives up to 2 uppercase initials from a workspace name.
    /// "Leaf Backend" → "LB", "Leaf" → "LE", "" → "?"
    private func initials(for name: String) -> String {
        let parts = name.split(separator: " ").map(String.init)
        if parts.count >= 2 {
            let a = parts[0].first.map(String.init) ?? ""
            let b = parts[1].first.map(String.init) ?? ""
            return (a + b).uppercased()
        } else if let first = parts.first, first.count >= 2 {
            let a = String(first.prefix(1))
            let b = String(first.dropFirst().prefix(1))
            return (a + b).uppercased()
        } else {
            return name.prefix(1).uppercased().isEmpty ? "?" : name.prefix(1).uppercased()
        }
    }
}
