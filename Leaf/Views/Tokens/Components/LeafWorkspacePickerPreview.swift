//
//  LeafWorkspacePickerPreview.swift
//  TokensPreview entry for Organism LeafWorkspacePicker. The popover
//  itself can't be captured statically, so the preview shows trigger-row
//  variants plus the popover content (LeafWorkspacePickerList) inline.
//

import LeafCore
import SwiftUI

#if DEBUG
  struct LeafWorkspacePickerPreview: View {
    var body: some View {
      VStack(alignment: .leading, spacing: LeafSpace.md) {
        Text("LeafWorkspacePicker")
          .font(LeafType.title.medium)
          .foregroundStyle(LeafColor.text.primary)

        // Variant 1 — empty (no workspaces → Add workspace CTA trigger)
        label("Trigger — empty (0 workspaces)")
        LeafWorkspacePicker(
          workspaces: [],
          activeWorkspaceID: nil,
          unreadCounts: [:],
          onSelect: { _ in },
          onAddNew: {},
          onJoin: {},
          onLeave: { _ in },
          onMarkAllRead: { _ in }
        )
        .frame(width: 260)

        // Variant 2 — active workspace, no unread elsewhere
        label("Trigger — active workspace, no unread")
        LeafWorkspacePicker(
          workspaces: [makeWS(id: "ws-1", name: "Leaf Backend")],
          activeWorkspaceID: "ws-1",
          unreadCounts: [:],
          onSelect: { _ in },
          onAddNew: {},
          onJoin: {},
          onLeave: { _ in },
          onMarkAllRead: { _ in }
        )
        .frame(width: 260)

        // Variant 3 — unread in a NON-active workspace → aggregate badge
        label("Trigger — 5 unread in another workspace")
        LeafWorkspacePicker(
          workspaces: [
            makeWS(id: "ws-a", name: "Alpha Team"),
            makeWS(id: "ws-b", name: "Beta Crew"),
          ],
          activeWorkspaceID: "ws-b",
          unreadCounts: ["ws-a": 5],
          onSelect: { _ in },
          onAddNew: {},
          onJoin: {},
          onLeave: { _ in },
          onMarkAllRead: { _ in }
        )
        .frame(width: 260)

        // Variant 4 — popover content rendered inline, 8 workspaces
        // (scroll cap), one soft-left dimmed, 99+ badge overflow
        label("Popover list — 8 workspaces · soft-left · 99+ overflow")
        LeafWorkspacePickerList(
          workspaces: eightWorkspaces,
          activeWorkspaceID: "ws-4",
          unreadCounts: ["ws-2": 3, "ws-6": 127],
          onSelect: { _ in },
          onAddNew: {},
          onJoin: {},
          onLeave: { _ in },
          onMarkAllRead: { _ in }
        )
        .background(LeafColor.surface.inset)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.md, style: .continuous))

        TokensInlineSpec(
          spec:
            "LeafWorkspacePicker · 36pt trigger (avatar + name + aggregate non-active unread + chevron) · popover 240pt: 32pt rows, checkmark indicator, LeafAvatar initials, LeafBadge(count:), context menu (Mark all read + Leave), scroll cap 280pt · footer: Add workspace + Join workspace",
          codeSnippet:
            "LeafWorkspacePicker(workspaces: ws, activeWorkspaceID: id, unreadCounts: counts, onSelect: {}, onAddNew: {}, onJoin: {}, onLeave: {}, onMarkAllRead: {})"
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
        makeWS(id: "ws-\(i + 1)", name: name, leftAt: i == 7 ? Date() : nil)
      }
    }
  }
#endif
