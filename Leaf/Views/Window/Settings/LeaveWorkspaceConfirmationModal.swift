//
//  LeaveWorkspaceConfirmationModal.swift
//  Track 5 / S7 — F.7. Confirmation sheet before leaving the active workspace.
//  Destructive CTA + async onConfirm with loading state.
//

import SwiftUI

struct LeaveWorkspaceConfirmationModal: View {
    let workspaceName: String
    let onConfirm: () async -> Void
    let onCancel: () -> Void

    @State private var isLeaving = false

    var body: some View {
        VStack(spacing: LeafSpace.md) {
            Text("Leave \(workspaceName)?")
                .font(LeafType.title.small)
                .foregroundStyle(LeafColor.text.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: LeafSpace.sm) {
                Text("You'll stop receiving messages and updates from this team.")
                    .font(LeafType.body.regular)
                    .foregroundStyle(LeafColor.text.secondary)
                Text("Your local message history will remain available for 30 days, then auto-delete.")
                    .font(LeafType.body.regular)
                    .foregroundStyle(LeafColor.text.secondary)
            }

            HStack(spacing: LeafSpace.sm) {
                LeafButton("Cancel", variant: .secondary, size: .md) {
                    onCancel()
                }
                .disabled(isLeaving)
                Spacer()
                LeafButton("Leave Workspace", variant: .destructive, size: .md) {
                    isLeaving = true
                    Task {
                        await onConfirm()
                        isLeaving = false
                    }
                }
                .disabled(isLeaving)
            }
        }
        .padding(LeafSpace.lg)
        .frame(width: 420)
    }
}
