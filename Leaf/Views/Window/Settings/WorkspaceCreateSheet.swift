//
//  WorkspaceCreateSheet.swift
//  Track 5 / S7 — F.9. Modal sheet for creating a new workspace.
//  Validates name (non-empty, ≤80 chars), shows inline error banner on failure,
//  delegates creation to WorkspaceReader (sets new WS as active + refreshes state).
//
//  Track 5 / S8 / T4 — Tier-gate wiring. When `TierGateReader.canCreateWorkspace`
//  is false (UserDefaults["tier"] = "free"), the [Create Workspace] button is
//  disabled and an inline UpgradeChip + per-callsite UpgradeModal `.sheet`
//  surfaces the early-access waitlist capture. Per arch reviewer I5 the modal
//  is owned by each callsite (NOT a WindowState global flag) — `@State
//  showUpgrade` lives here.
//

import SwiftUI
import LeafCore

struct WorkspaceCreateSheet: View {
    let onCreated: () -> Void
    let onCancel: () -> Void

    @Environment(WorkspaceReader.self) private var workspaceReader
    /// T4 — read tier gate to disable [Create] + show UpgradeChip when Free.
    @Environment(TierGateReader.self) private var tierGate
    /// T4 — composition-root closure that wraps SupabaseClient.submitToWaitlist.
    @Environment(\.submitToWaitlist) private var submitToWaitlist

    @State private var nameDraft = ""
    @State private var isCreating = false
    @State private var errorMessage: String?
    /// T4 — per-callsite UpgradeModal state. Mirrors S6 cross-post sheet pattern.
    @State private var showUpgrade = false
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

            // T4 — inline UpgradeChip shown ABOVE form when Free-tier blocks creation.
            // Form fields remain visible (Free user can still see the UI surface +
            // understand what unlocking gets them) but [Create] is disabled.
            if !tierGate.canCreateWorkspace {
                upgradeChip(message: "Workspace creation requires Leaf Team")
            }

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
                .disabled(!tierGate.canCreateWorkspace || !canCreate || isCreating)
            }
        }
        .padding(LeafSpace.lg)
        .frame(width: 440)
        .onAppear { isFocused = true }
        .sheet(isPresented: $showUpgrade) {
            UpgradeModal(
                reason: .createWorkspace,
                onDismiss: { showUpgrade = false },
                onSubmitEmail: { email in await submitToWaitlist(email) }
            )
        }
    }

    // MARK: - Helpers

    /// T4 — small inline UpgradeChip used as the disabled-state overlay. Kept
    /// inline (vs new LeafKit atom) because no other callsite needs this shape:
    /// SendDirectMessageSheet uses the same pattern, AcceptInviteSheet
    /// replaces the [Join] button entirely instead.
    @ViewBuilder
    private func upgradeChip(message: String) -> some View {
        HStack(spacing: LeafSpace.sm) {
            Image(systemName: "lock.fill")
                .foregroundStyle(LeafColor.status.warning)
            Text(message)
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.primary)
            Spacer()
            LeafButton("Upgrade", variant: .primary, size: .sm) {
                showUpgrade = true
            }
        }
        .padding(LeafSpace.sm)
        .background(LeafColor.status.warning.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.sm, style: .continuous))
    }

    private func createIfValid() {
        // T4 — defence in depth: if user somehow bypasses the disabled state
        // (keyboard submit, accessibility), block here too.
        guard tierGate.canCreateWorkspace else {
            showUpgrade = true
            return
        }
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
