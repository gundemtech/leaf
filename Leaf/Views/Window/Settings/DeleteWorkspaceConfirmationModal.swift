//
//  DeleteWorkspaceConfirmationModal.swift
//  Track 5 / S7 — F.8. Admin-only confirmation sheet before permanently deleting
//  a workspace. Requires typing the workspace name verbatim to enable the CTA.
//

import SwiftUI

struct DeleteWorkspaceConfirmationModal: View {
    let workspaceName: String
    let onConfirm: () async -> Void
    let onCancel: () -> Void

    @State private var typedName = ""
    @State private var isDeleting = false
    @FocusState private var isFocused: Bool

    private var canConfirm: Bool {
        typedName == workspaceName
    }

    var body: some View {
        VStack(spacing: LeafSpace.md) {
            Text("Delete \(workspaceName)?")
                .font(LeafType.title.small)
                .foregroundStyle(LeafColor.text.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: LeafSpace.sm) {
                Text("This permanently removes the workspace for **all members**. All messages and shared events will be deleted after 30 days.")
                    .font(LeafType.body.regular)
                    .foregroundStyle(LeafColor.text.secondary)
                Text("This cannot be undone.")
                    .font(LeafType.body.regular)
                    .foregroundStyle(LeafColor.status.danger)
            }

            VStack(alignment: .leading, spacing: LeafSpace.xs) {
                Text("Type **\(workspaceName)** to confirm")
                    .font(LeafType.caption)
                    .foregroundStyle(LeafColor.text.tertiary)
                TextField(workspaceName, text: $typedName)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
            }

            HStack(spacing: LeafSpace.sm) {
                LeafButton("Cancel", variant: .secondary, size: .md) {
                    onCancel()
                }
                .disabled(isDeleting)
                Spacer()
                LeafButton("Delete Permanently", variant: .destructive, size: .md) {
                    isDeleting = true
                    Task {
                        await onConfirm()
                        isDeleting = false
                    }
                }
                .disabled(!canConfirm || isDeleting)
            }
        }
        .padding(LeafSpace.lg)
        .frame(width: 460)
        .onAppear { isFocused = true }
    }
}
