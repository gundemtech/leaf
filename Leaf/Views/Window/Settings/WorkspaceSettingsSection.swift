//
//  WorkspaceSettingsSection.swift
//  Track 5 / S7 — F.1 + F.2 + F.10. Settings → Workspace section host.
//  Renders workspace header row (name editor + created date + member count),
//  member admin list, pending invites admin section, and action buttons row
//  (Invite / New Workspace / Leave / Delete Permanently).
//

import CryptoKit
import SwiftUI
import LeafCore

struct WorkspaceSettingsSection: View {
    @Environment(WorkspaceReader.self) private var workspaceReader
    @Environment(PendingInvitesReader.self) private var pendingInvitesReader

    @State private var generateInvitePresented = false
    @State private var createWorkspacePresented = false
    @State private var leavePresented = false
    @State private var deletePresented = false
    /// Track 5 / S8 / T8 — Wipe cache data (hard-wipe) modal trigger.
    @State private var hardWipePresented = false
    @State private var myPubHex: String = ""
    /// S7 Stage 6 fix C-I5 + C-I8 — most recent destructive-op error surfaced
    /// as an inline LeafBanner above the action buttons. Reads the operation
    /// outcome from the return value of `workspaceReader.delete(...)` /
    /// `leaveWorkspace(...)` instead of inspecting reader.state (which
    /// conflates fresh op result with stale prior errors).
    @State private var lastActionError: String?

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
                ActiveTokensSection()       // M027 invite-redesign — admin token mgmt
                PendingRequestsSection()    // M027 invite-redesign — admin queue
                PendingInvitesSection()     // S3 legacy back-compat (deprecates ≤30d post-ship)
                actionButtonsRow
            }
        }
        .onAppear { loadMyPubHex() }
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

    // MARK: - F.10 — Action buttons row

    @ViewBuilder
    private var actionButtonsRow: some View {
        if case .loaded(_, let active, let members) = workspaceReader.state {
            let viewerIsAdmin = members.contains { $0.pubkeyHex == myPubHex && $0.role == .admin }

            HStack(spacing: LeafSpace.sm) {
                LeafButton("+ Invite teammate", variant: .secondary, size: .md) {
                    generateInvitePresented = true
                }
                LeafButton("+ New Workspace", variant: .secondary, size: .md) {
                    createWorkspacePresented = true
                }
                Spacer()
                LeafButton("Leave Workspace", variant: .destructive, size: .md) {
                    leavePresented = true
                }
                if viewerIsAdmin {
                    LeafButton("Delete Permanently", variant: .destructive, size: .md) {
                        deletePresented = true
                    }
                }
            }
            .padding(.top, LeafSpace.md)
            .sheet(isPresented: $generateInvitePresented) {
                GenerateInviteSheet()
            }
            .sheet(isPresented: $createWorkspacePresented) {
                WorkspaceCreateSheet(
                    onCreated: { createWorkspacePresented = false },
                    onCancel: { createWorkspacePresented = false }
                )
            }
            .sheet(isPresented: $leavePresented) {
                LeaveWorkspaceConfirmationModal(
                    workspaceName: active.name,
                    onConfirm: {
                        // leaveActiveWorkspace doesn't return a Result yet —
                        // the underlying operation is local-only (markLeft +
                        // re-resolve active). state.error still drives the
                        // failure surface here pending future refactor.
                        workspaceReader.leaveActiveWorkspace()
                        leavePresented = false
                    },
                    onCancel: { leavePresented = false }
                )
            }
            .sheet(isPresented: $deletePresented) {
                DeleteWorkspaceConfirmationModal(
                    workspaceName: active.name,
                    onConfirm: {
                        // S7 Stage 6 fix C-I5 + C-I8 — read per-operation
                        // outcome from the return value (nil = success;
                        // non-nil = surface message). Stale reader.state
                        // .error from prior refresh failures no longer
                        // pollutes this destructive op's UX signal.
                        let err = await workspaceReader.delete(workspaceID: active.id)
                        lastActionError = err
                        if err == nil {
                            deletePresented = false
                        }
                    },
                    onCancel: { deletePresented = false }
                )
            }
            // Track 5 / S8 / T8 — «Wipe cache data» destructive action visible
            // only when the workspace has `left_at_ms` OR `deleted_at_ms` set.
            // Closes S7 C-I7 honest-copy promise («auto-delete after 30 days»)
            // by offering the manual wipe path immediately after Leave or
            // admin Delete. Auto-pruner sweeps abandoned rows on the 30d
            // schedule independently.
            if active.leftAt != nil || active.deletedAt != nil {
                HStack(spacing: LeafSpace.sm) {
                    Spacer()
                    LeafButton(
                        "Wipe cache data",
                        variant: .destructive,
                        size: .md,
                        icon: .system("trash.fill")
                    ) {
                        hardWipePresented = true
                    }
                }
                .padding(.top, LeafSpace.sm)
                .sheet(isPresented: $hardWipePresented) {
                    WorkspaceHardWipeConfirmationModal(
                        workspaceName: active.name,
                        onConfirm: {
                            let err = await workspaceReader.hardDelete(workspaceID: active.id)
                            lastActionError = err
                            if err == nil {
                                hardWipePresented = false
                            }
                            return err
                        },
                        onCancel: { hardWipePresented = false }
                    )
                }
            }
            if let err = lastActionError {
                LeafBanner(
                    tone: .danger,
                    title: "Workspace action failed",
                    description: err,
                    onDismiss: { lastActionError = nil }
                )
                .padding(.top, LeafSpace.sm)
            }
        }
    }

    // MARK: - Helpers

    private func relativeDate(_ date: Date) -> String {
        Self.createdFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func loadMyPubHex() {
        guard myPubHex.isEmpty else { return }
        do {
            let priv = try IdentityService.ensureLocalIdentity(at: TeamKeystore.defaultRoot())
            myPubHex = priv.publicKey.rawRepresentation
                .map { String(format: "%02x", $0) }.joined()
        } catch {
            myPubHex = ""
        }
    }
}
