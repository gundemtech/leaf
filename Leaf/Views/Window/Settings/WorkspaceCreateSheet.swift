//
//  WorkspaceCreateSheet.swift
//  Track 5 / S7 — F.9. Modal sheet for creating a new workspace.
//  Validates name (non-empty, ≤80 chars), shows inline error banner on failure,
//  delegates creation to WorkspaceReader (sets new WS as active + refreshes state).
//

import SwiftUI
import LeafCore

struct WorkspaceCreateSheet: View {
    let onCreated: () -> Void
    let onCancel: () -> Void

    @Environment(WorkspaceReader.self) private var workspaceReader

    @State private var nameDraft = ""
    @State private var isCreating = false
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    private var canCreate: Bool {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 80
    }

    var body: some View {
        VStack(spacing: LeafSpace.md) {
            Text("Create new workspace")
                .font(LeafType.title.small)
                .foregroundStyle(LeafColor.text.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: LeafSpace.xs) {
                Text("Workspace name")
                    .font(LeafType.caption)
                    .foregroundStyle(LeafColor.text.tertiary)
                TextField("Acme Team", text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .onSubmit { createIfValid() }
            }

            if let err = errorMessage {
                LeafBanner(tone: .danger, title: err, description: nil, onDismiss: { errorMessage = nil })
            }

            HStack(spacing: LeafSpace.sm) {
                LeafButton("Cancel", variant: .secondary, size: .md) {
                    onCancel()
                }
                .disabled(isCreating)
                Spacer()
                LeafButton("Create Workspace", variant: .primary, size: .md) {
                    createIfValid()
                }
                .disabled(!canCreate || isCreating)
            }
        }
        .padding(LeafSpace.lg)
        .frame(width: 440)
        .onAppear { isFocused = true }
    }

    private func createIfValid() {
        guard canCreate, !isCreating else { return }
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        isCreating = true
        errorMessage = nil
        workspaceReader.createWorkspace(displayName: trimmed)
        // Reflect any error that WorkspaceReader transitioned into.
        if case .error(let msg) = workspaceReader.state {
            errorMessage = msg
            isCreating = false
        } else {
            onCreated()
        }
    }
}
