//
//  WorkspaceNameEditor.swift
//  Track 5 / S7 — F.3. Inline workspace-name editor row inside WorkspaceSettingsSection.
//  States: display (Text + pencil icon) ↔ editing (TextField + Save/Cancel).
//  Commits via WorkspaceReader.rename(workspaceID:newName:) — async Supabase PATCH
//  then local UPDATE. Validation: 1-80 non-whitespace characters.
//

import SwiftUI
import LeafCore

struct WorkspaceNameEditor: View {
    let workspaceID: String
    let currentName: String

    @Environment(WorkspaceReader.self) private var workspaceReader
    @State private var isEditing = false
    @State private var draft: String = ""
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.xs) {
            HStack(spacing: LeafSpace.sm) {
                if isEditing {
                    TextField("Workspace name", text: $draft)
                        .textFieldStyle(.plain)
                        .font(LeafType.title.small)
                        .foregroundStyle(LeafColor.text.primary)
                        .focused($isFocused)
                        .onSubmit { Task { await commitRename() } }

                    LeafButton("Cancel", variant: .secondary, size: .sm, action: cancelEdit)

                    LeafButton("Save", variant: .primary, size: .sm, action: {
                        Task { await commitRename() }
                    })
                    .disabled(isInvalid(draft))
                } else {
                    Text(currentName)
                        .font(LeafType.title.small)
                        .foregroundStyle(LeafColor.text.primary)

                    LeafIconButton(
                        systemName: "pencil",
                        variant: .ghost,
                        size: .sm,
                        action: startEdit
                    )
                }
                Spacer()
            }

            if let err = errorMessage {
                LeafBanner(
                    tone: .danger,
                    title: "Rename failed",
                    description: err,
                    onDismiss: { errorMessage = nil }
                )
            }
        }
    }

    // MARK: - Actions

    private func startEdit() {
        draft = currentName
        errorMessage = nil
        isEditing = true
        DispatchQueue.main.async { isFocused = true }
    }

    private func cancelEdit() {
        isEditing = false
        errorMessage = nil
    }

    private func commitRename() async {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isInvalid(draft) else { return }
        // S7 Stage 6 fix C-I5 + C-I8 — read the per-operation outcome from
        // the rename(...) return value rather than inspecting
        // workspaceReader.state. The latter conflates "this rename's result"
        // with "current reader state" — a lingering .error from a prior
        // refresh failure would falsely report this rename as failed.
        let errorOrNil = await workspaceReader.rename(workspaceID: workspaceID, newName: trimmed)
        if let err = errorOrNil {
            errorMessage = err
        } else {
            isEditing = false
            errorMessage = nil
        }
    }

    // MARK: - Validation

    private func isInvalid(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.count > 80
    }
}
