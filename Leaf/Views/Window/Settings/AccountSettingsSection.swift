//
//  AccountSettingsSection.swift
//  Track 5 / S8 / T9 — Settings page top section. Surfaces user identity
//  (display name from active workspace's self-member if available; Join
//  code copy button) + current Tier chip + Free→Upgrade button.
//
//  Display name resolution: walks `WorkspaceReader.state` → active workspace
//  members → first row where `pubkeyHex == self`. Falls back to "Anonymous"
//  when no workspace has been joined yet (fresh-install path).
//
//  Tier chip variants:
//    .team  → green capsule with checkmark.seal.fill + "Team — early access"
//    .free  → "Upgrade" LeafButton triggering UpgradeModal (reuses the
//             T3/T4 modal + .submitToWaitlist env closure).
//
//  Join code: human-readable encoding (ABCD-EFGH-…) of the X25519 pubkey
//  via JoinCode.encode. Shared with admins of *other* workspaces who want
//  to invite you (they paste it into GenerateInviteSheet's "Paste Join
//  code" field). The raw 64-hex pubkey is the same bytes in a different
//  representation; admins of OTHER workspaces accept either form, but the
//  Join code carries a checksum so typos are caught before invite
//  generation. Pre-T11 this section showed truncated hex, which leaked
//  the implementation form into the UI and gave admin-path users no
//  visible way to be invited to a second workspace.
//

import AppKit
import CryptoKit
import SwiftUI
import LeafCore

struct AccountSettingsSection: View {
    @Environment(TierGateReader.self) private var tierGate
    @Environment(WorkspaceReader.self) private var workspaceReader
    @Environment(\.submitToWaitlist) private var submitToWaitlist

    @State private var selfPubHex: String = ""
    @State private var selfJoinCode: String = ""
    @State private var showUpgrade = false

    var body: some View {
        LeafSection(
            title: "Account",
            description: "Your local identity. Send your Join code to anyone who wants to invite you to their workspace — they paste it into their invite sheet, then send the link back to you."
        ) {
            LeafCard(variant: .raised, padding: .regular) {
                HStack(alignment: .top, spacing: LeafSpace.md) {
                    avatar
                    VStack(alignment: .leading, spacing: LeafSpace.xs) {
                        Text(displayName)
                            .font(LeafType.title.small)
                            .foregroundStyle(LeafColor.text.primary)
                        joinCodeRow
                    }
                    Spacer(minLength: 0)
                    tierChip
                }
            }
        }
        .sheet(isPresented: $showUpgrade) {
            UpgradeModal(
                reason: .createWorkspace,
                onDismiss: { showUpgrade = false },
                onSubmitEmail: { email in await submitToWaitlist(email) }
            )
        }
        .task {
            loadSelfIdentity()
        }
    }

    // MARK: - Subviews

    private var avatar: some View {
        Image(systemName: "person.crop.circle.fill")
            .font(.system(size: 32))
            .foregroundStyle(LeafColor.accent.primary)
            .frame(width: 36, height: 36)
    }

    @ViewBuilder
    private var joinCodeRow: some View {
        if selfJoinCode.isEmpty {
            Text("Generating identity…")
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.tertiary)
        } else {
            VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                Text("YOUR JOIN CODE")
                    .leafSectionLabel()
                    .foregroundStyle(LeafColor.text.tertiary)
                HStack(spacing: LeafSpace.xs) {
                    Text(selfJoinCode)
                        .font(LeafType.mono.small)
                        .foregroundStyle(LeafColor.text.primary)
                        .textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(selfJoinCode, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                            .foregroundStyle(LeafColor.text.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy your Join code to clipboard")
                }
            }
        }
    }

    @ViewBuilder
    private var tierChip: some View {
        switch tierGate.tier {
        case .team:
            HStack(spacing: LeafSpace.xs) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 12))
                Text("Team — early access")
                    .font(LeafType.body.small)
            }
            .padding(.horizontal, LeafSpace.sm)
            .padding(.vertical, LeafSpace.xs)
            .background(
                Capsule().fill(LeafColor.status.success.opacity(0.15))
            )
            .foregroundStyle(LeafColor.status.success)
        case .free:
            LeafButton(
                "Upgrade",
                variant: .primary,
                size: .sm
            ) {
                showUpgrade = true
            }
        }
    }

    // MARK: - Helpers

    /// Display name resolution — pulls from the active workspace's self-member
    /// when a workspace is loaded. Fresh-install (no workspace) → "Anonymous".
    private var displayName: String {
        if case .loaded(_, _, let members) = workspaceReader.state,
           !selfPubHex.isEmpty,
           let me = members.first(where: { $0.pubkeyHex == selfPubHex }),
           !me.displayName.isEmpty {
            return me.displayName
        }
        return "Anonymous"
    }

    /// Resolve self pubkey from `IdentityService.ensureLocalIdentity` via the
    /// shared TeamKeystore root + encode to Join code format. Filesystem I/O
    /// — done once in `.task`. `selfPubHex` is kept for `displayName`
    /// resolution (matching against `TeamMember.pubkeyHex` in the active
    /// workspace member list).
    private func loadSelfIdentity() {
        do {
            let priv = try IdentityService.ensureLocalIdentity(at: TeamKeystore.defaultRoot())
            let bytes = priv.publicKey.rawRepresentation
            selfPubHex = bytes.map { String(format: "%02x", $0) }.joined()
            selfJoinCode = try JoinCode.encode(pubkey: bytes)
        } catch {
            // Leave both empty → "Generating identity…" placeholder.
            // Composition root logs identity errors elsewhere; UI just shows
            // a neutral state instead of crashing.
            selfPubHex = ""
            selfJoinCode = ""
        }
    }
}
