//
//  WorkspaceMemberAdminRow.swift
//  Track 5 / S7 — F.5. Single member row inside WorkspaceMembersAdminList.
//  Shows avatar + display name + "(you)" hint + joined date + role pill.
//  Admin sees ellipsis context menu on non-self rows; tapping "Remove" shows
//  confirmationDialog. Actual removal wired in Phase H composition root
//  (KeyRotationService.removeMember). MVP: dialog button is no-op placeholder.
//

import SwiftUI
import LeafCore

struct WorkspaceMemberAdminRow: View {
    let member: TeamMember
    let isMe: Bool
    let viewerIsAdmin: Bool

    @State private var removeConfirmPresented = false

    private static let joinedFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    var body: some View {
        HStack(spacing: LeafSpace.sm) {
            LeafAvatar(initials: initials(for: member.displayName), size: .sm)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: LeafSpace.xs) {
                    Text(member.displayName)
                        .font(LeafType.body.regular)
                        .foregroundStyle(LeafColor.text.primary)
                        .lineLimit(1)

                    if isMe {
                        Text("(you)")
                            .font(LeafType.caption)
                            .foregroundStyle(LeafColor.text.tertiary)
                    }
                }

                Text("Joined \(relativeDate(member.addedAt))")
                    .font(LeafType.caption)
                    .foregroundStyle(LeafColor.text.tertiary)
            }

            Spacer()

            LeafPill(
                title: member.role == .admin ? "Admin" : "Member",
                tone: member.role == .admin ? .accent : .neutral
            )

            if viewerIsAdmin && !isMe {
                Menu {
                    Button("Remove from workspace", role: .destructive) {
                        removeConfirmPresented = true
                    }
                } label: {
                    LeafIcon(
                        systemName: "ellipsis",
                        size: .md,
                        tint: LeafColor.text.tertiary
                    )
                }
                .menuStyle(.borderlessButton)
                .frame(width: LeafSpace.xxl)
            }
        }
        .frame(minHeight: 44)
        .confirmationDialog(
            "Remove \(member.displayName)?",
            isPresented: $removeConfirmPresented,
            titleVisibility: .visible
        ) {
            Button("Remove from workspace", role: .destructive) {
                // Phase H — KeyRotationService.removeMember(workspaceID:memberID:) wired here.
            }
            Button("Cancel", role: .cancel) {
                removeConfirmPresented = false
            }
        } message: {
            Text("Their access to this workspace will be revoked. Existing shared data remains in their local history.")
        }
    }

    // MARK: - Helpers

    private func initials(for name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
            .uppercased()
        return parts.isEmpty ? "?" : parts
    }

    private func relativeDate(_ date: Date) -> String {
        Self.joinedFormatter.localizedString(for: date, relativeTo: Date())
    }
}
