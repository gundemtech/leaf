//
//  LeafWorkspacePickerPreview.swift
//  TokensPreview entry for Organism LeafWorkspacePicker. The popover
//  itself can't be captured statically, so the preview shows trigger-row
//  variants plus the popover content (LeafWorkspacePickerList) inline.
//  The sidebar bottom card (trigger + divider + profile row) is composed
//  in Sidebar — trigger variants here get a bare card background only.
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
        card(
          LeafWorkspacePicker(
            workspaces: [],
            activeWorkspaceID: nil,
            unreadCounts: [:],
            isOpen: .constant(false),
            triggerFrame: .constant(.zero)
          )
        )

        // Variant 2 — single active workspace (no count caption)
        label("Trigger — single workspace")
        card(
          LeafWorkspacePicker(
            workspaces: [makeWS(id: "ws-1", name: "Leaf Backend")],
            activeWorkspaceID: "ws-1",
            unreadCounts: [:],
            isOpen: .constant(false),
            triggerFrame: .constant(.zero)
          )
        )

        // Variant 3 — multi-workspace: count caption + aggregate badge
        // for unread sitting in a NON-active workspace
        label("Trigger — 8 workspaces, 5 unread elsewhere")
        card(
          LeafWorkspacePicker(
            workspaces: eightWorkspaces,
            activeWorkspaceID: "ws-4",
            unreadCounts: ["ws-2": 5],
            isOpen: .constant(false),
            triggerFrame: .constant(.zero)
          )
        )

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
        .clipShape(
          RoundedRectangle(
            cornerRadius: LeafWorkspacePickerTokens.cardCornerRadius,
            style: .continuous
          )
        )

        TokensInlineSpec(
          spec:
            "LeafWorkspacePicker · 38pt trigger (square LeafWorkspaceMark + name + count caption + aggregate non-active unread + chevron) · popover 260pt: 34pt rows, tinted marks, trailing checkmark on active, LeafBadge(count:), context menu (Mark all read + Leave), scroll cap 320pt · footer menu-rows: Add + Join",
          codeSnippet:
            "LeafWorkspacePicker(workspaces: ws, activeWorkspaceID: id, unreadCounts: counts, isOpen: $open, triggerFrame: $frame) + LeafWorkspacePickerDropdown(... onDismiss:) at Sidebar root"
        )
      }
      .padding(LeafSpace.lg)
      .background(LeafColor.surface.raised)
      .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
    }

    // MARK: - Helpers

    private func card(_ content: some View) -> some View {
      content
        .padding(LeafWorkspacePickerTokens.sectionPadding)
        .background(
          RoundedRectangle(
            cornerRadius: LeafWorkspacePickerTokens.cardCornerRadius,
            style: .continuous
          )
          .fill(LeafColor.surface.inset)
        )
        .frame(width: 260)
    }

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
