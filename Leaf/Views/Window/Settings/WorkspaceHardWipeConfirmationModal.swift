//
//  WorkspaceHardWipeConfirmationModal.swift
//  Track 5 / S8 / T8 — type-name friction modal for the manual «Wipe cache
//  data» destructive action in Settings → Workspace.
//
//  Visible only when the workspace has `left_at_ms` OR `deleted_at_ms` set
//  (gated upstream in WorkspaceSettingsSection). Pattern mirrors
//  DeleteWorkspaceConfirmationModal (verbatim-name match) with two
//  differences:
//    1. Body copy reflects local-cache-only wipe + audit-metadata preserved.
//    2. Name match uses NFC normalization (sec M8) so Unicode keyboard input
//       (composed vs decomposed forms) doesn't false-negative — relevant for
//       workspace names that include diacritics from accented IME input.
//

import SwiftUI

struct WorkspaceHardWipeConfirmationModal: View {
    let workspaceName: String
    let onConfirm: () async -> String?  // nil = success, else error
    let onCancel: () -> Void

    @State private var typedName = ""
    @State private var isWiping = false
    @State private var errorText: String?
    @FocusState private var isFocused: Bool

    /// NFC normalize per sec M8 — keyboard-layout Unicode edge cases
    /// (precomposed vs decomposed forms of accented characters) should not
    /// false-negative the match against the canonical workspace name.
    private var canConfirm: Bool {
        typedName.precomposedStringWithCanonicalMapping ==
            workspaceName.precomposedStringWithCanonicalMapping
    }

    var body: some View {
        VStack(spacing: LeafSpace.md) {
            Text("Wipe \(workspaceName) cache data?")
                .font(LeafType.title.small)
                .foregroundStyle(LeafColor.text.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: LeafSpace.sm) {
                Text("This permanently removes the local message history, shared events, attachment cache, and pending invites for **this workspace on this device**.")
                    .font(LeafType.body.regular)
                    .foregroundStyle(LeafColor.text.secondary)
                Text("Workspace audit metadata (team keys and member roster) is preserved per privacy contract.")
                    .font(LeafType.caption)
                    .foregroundStyle(LeafColor.text.tertiary)
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

            if let errorText {
                Text(errorText)
                    .font(LeafType.caption)
                    .foregroundStyle(LeafColor.status.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: LeafSpace.sm) {
                LeafButton("Cancel", variant: .secondary, size: .md) {
                    onCancel()
                }
                .disabled(isWiping)
                Spacer()
                LeafButton("Wipe data", variant: .destructive, size: .md, isLoading: isWiping) {
                    isWiping = true
                    errorText = nil
                    Task {
                        let err = await onConfirm()
                        isWiping = false
                        if let err {
                            errorText = err
                        }
                        // On success the caller dismisses the sheet (it
                        // observes the nil return); no need to onCancel here.
                    }
                }
                .disabled(!canConfirm || isWiping)
            }
        }
        .padding(LeafSpace.lg)
        .frame(width: 460)
        .onAppear { isFocused = true }
    }
}
