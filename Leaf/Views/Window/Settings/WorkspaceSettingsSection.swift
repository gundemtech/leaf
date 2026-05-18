//
//  WorkspaceSettingsSection.swift
//  Track 5 / S7 — F.1 + F.2. Settings → Workspace section host.
//  Renders workspace header row (name editor + created date + member count),
//  member admin list, and pending invites admin section.
//  F.10 action buttons (Invite / Leave / Delete / New) wired in the next dispatch.
//

import SwiftUI
import LeafCore

struct WorkspaceSettingsSection: View {
    @Environment(WorkspaceReader.self) private var workspaceReader
    @Environment(PendingInvitesReader.self) private var pendingInvitesReader

    private static let createdFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    var body: some View {
        LeafSection(
            title: "Workspace",
            description: "Your team workspace identity, members, and invites."
        ) {
            VStack(spacing: LeafSpace.md) {
                workspaceHeaderRow
                WorkspaceMembersAdminList()
                PendingInvitesSection()
                actionButtonsRow
            }
        }
    }

    // MARK: - F.2 — Header row

    @ViewBuilder
    private var workspaceHeaderRow: some View {
        if case .loaded(_, let active, let members) = workspaceReader.state {
            LeafCard(variant: .raised, padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.sm) {
                    WorkspaceNameEditor(
                        workspaceID: active.id,
                        currentName: active.name
                    )

                    HStack(spacing: LeafSpace.lg) {
                        LeafIconLabel(
                            icon: .system("calendar"),
                            title: "Created \(relativeDate(active.createdAt))",
                            iconTint: LeafColor.text.tertiary,
                            titleStyle: LeafType.caption
                        )

                        LeafIconLabel(
                            icon: .system("person.2"),
                            title: "\(members.count) member\(members.count == 1 ? "" : "s")",
                            iconTint: LeafColor.text.tertiary,
                            titleStyle: LeafType.caption
                        )
                    }
                    .foregroundStyle(LeafColor.text.tertiary)
                }
            }
        }
    }

    // MARK: - F.10 placeholder

    @ViewBuilder
    private var actionButtonsRow: some View {
        // Placeholder — Phase F.10 fills with Invite / Leave / Delete / New workspace buttons.
        EmptyView()
    }

    // MARK: - Helpers

    private func relativeDate(_ date: Date) -> String {
        Self.createdFormatter.localizedString(for: date, relativeTo: Date())
    }
}
