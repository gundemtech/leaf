//
//  LeafWorkspaceSwitcherPreview.swift
//  Track 5 / S7 — TokensPreview entry for Organism LeafWorkspaceSwitcher.
//  6 variants: empty / single-active / 3-ws-unread / 8-ws-stack /
//  soft-left / 99+-overflow.
//

import SwiftUI
import LeafCore

#if DEBUG
struct LeafWorkspaceSwitcherPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("LeafWorkspaceSwitcher")
                .font(LeafType.title.medium)
                .foregroundStyle(LeafColor.text.primary)

            // Variant 1 — empty (no workspaces, just Add New row)
            label("Empty — 0 workspaces")
            LeafWorkspaceSwitcher(
                workspaces: [],
                activeWorkspaceID: nil,
                unreadCounts: [:],
                onSelect: { _ in },
                onAddNew: { },
                onJoin: { },
                onLeave: { _ in },
                onMarkAllRead: { _ in }
            )
            .frame(width: 260)

            // Variant 2 — single active, no unread
            label("Single workspace (active, no unread)")
            LeafWorkspaceSwitcher(
                workspaces: [makeWS(id: "ws-1", name: "Leaf Backend")],
                activeWorkspaceID: "ws-1",
                unreadCounts: [:],
                onSelect: { _ in },
                onAddNew: { },
                onJoin: { },
                onLeave: { _ in },
                onMarkAllRead: { _ in }
            )
            .frame(width: 260)

            // Variant 3 — 3 workspaces, second active, first has 5 unread
            label("3 workspaces — second active, first has 5 unread")
            LeafWorkspaceSwitcher(
                workspaces: [
                    makeWS(id: "ws-a", name: "Alpha Team"),
                    makeWS(id: "ws-b", name: "Beta Crew"),
                    makeWS(id: "ws-c", name: "Core Platform"),
                ],
                activeWorkspaceID: "ws-b",
                unreadCounts: ["ws-a": 5],
                onSelect: { _ in },
                onAddNew: { },
                onJoin: { },
                onLeave: { _ in },
                onMarkAllRead: { _ in }
            )
            .frame(width: 260)

            // Variant 4 — 8 workspaces (stacking / scroll behavior)
            label("8 workspaces — stacking density test")
            LeafWorkspaceSwitcher(
                workspaces: eightWorkspaces,
                activeWorkspaceID: "ws-4",
                unreadCounts: ["ws-2": 3, "ws-6": 12],
                onSelect: { _ in },
                onAddNew: { },
                onJoin: { },
                onLeave: { _ in },
                onMarkAllRead: { _ in }
            )
            .frame(width: 260)

            // Variant 5 — soft-left workspace dimmed
            label("Soft-left workspace (leftAt != nil) — dimmed tertiary text")
            LeafWorkspaceSwitcher(
                workspaces: [
                    makeWS(id: "ws-x", name: "Active Workspace"),
                    makeWS(id: "ws-y", name: "Left Workspace", leftAt: Date()),
                ],
                activeWorkspaceID: "ws-x",
                unreadCounts: [:],
                onSelect: { _ in },
                onAddNew: { },
                onJoin: { },
                onLeave: { _ in },
                onMarkAllRead: { _ in }
            )
            .frame(width: 260)

            // Variant 6 — 99+ unread overflow
            label("99+ unread overflow badge")
            LeafWorkspaceSwitcher(
                workspaces: [
                    makeWS(id: "ws-flood", name: "Flood Channel"),
                ],
                activeWorkspaceID: "ws-flood",
                unreadCounts: ["ws-flood": 127],
                onSelect: { _ in },
                onAddNew: { },
                onJoin: { },
                onLeave: { _ in },
                onMarkAllRead: { _ in }
            )
            .frame(width: 260)

            TokensInlineSpec(
                spec: "LeafWorkspaceSwitcher · 32pt rows · checkmark/circle indicator · LeafAvatar initials · LeafBadge(count:) · context menu (Mark all read + Leave) · soft-left dimmed · footer rows: Add workspace + Join workspace",
                codeSnippet: "LeafWorkspaceSwitcher(workspaces: ws, activeWorkspaceID: id, unreadCounts: counts, onSelect: {}, onAddNew: {}, onJoin: {}, onLeave: {}, onMarkAllRead: {})"
            )
        }
        .padding(LeafSpace.lg)
        .background(LeafColor.surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
    }

    // MARK: - Helpers

    private func label(_ text: String) -> some View {
        Text(text)
            .font(LeafType.body.small)
            .foregroundStyle(LeafColor.text.secondary)
    }

    private func makeWS(id: String, name: String, leftAt: Date? = nil) -> Workspace {
        Workspace(
            id: id,
            name: name,
            createdAt: Date(timeIntervalSince1970: 0),
            createdByMemberID: "member-0",
            leftAt: leftAt
        )
    }

    private var eightWorkspaces: [Workspace] {
        let names = [
            "Alpha Engineering", "Beta Design", "Core Platform",
            "Data Science", "Edge Services", "Frontend Guild",
            "Growth Team", "Infra Ops",
        ]
        return names.enumerated().map { i, name in
            makeWS(id: "ws-\(i + 1)", name: name)
        }
    }
}
#endif
