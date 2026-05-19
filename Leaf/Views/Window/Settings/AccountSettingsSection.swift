//
//  AccountSettingsSection.swift
//  Track 5 / S8 / T9 — Settings page top section. Surfaces user identity
//  (display name from active workspace's self-member if available; pubkey
//  copy button) + current Tier chip + Free→Upgrade button.
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
//  Pubkey copy: shows first 16 chars + "…", clipboard receives the FULL
//  64-hex string. SF Symbol `doc.on.doc` for the copy affordance; `help()`
//  tooltip clarifies intent.
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
    @State private var showUpgrade = false

    var body: some View {
        LeafSection(
            title: "Account",
            description: "Your local identity. The pubkey is shared with workspaces you join; nothing else leaves your device by default."
        ) {
            LeafCard(variant: .raised, padding: .regular) {
                HStack(alignment: .top, spacing: LeafSpace.md) {
                    avatar
                    VStack(alignment: .leading, spacing: LeafSpace.xs) {
                        Text(displayName)
                            .font(LeafType.title.small)
                            .foregroundStyle(LeafColor.text.primary)
                        pubkeyRow
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
            loadSelfPubHex()
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
    private var pubkeyRow: some View {
        if selfPubHex.isEmpty {
            Text("Generating identity…")
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.tertiary)
        } else {
            HStack(spacing: LeafSpace.xs) {
                Text(pubkeyDisplay)
                    .font(LeafType.mono.small)
                    .foregroundStyle(LeafColor.text.secondary)
                    .textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(selfPubHex, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundStyle(LeafColor.text.tertiary)
                }
                .buttonStyle(.plain)
                .help("Copy full pubkey to clipboard")
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

    /// Pubkey display: first 16 chars + ellipsis. Full hex available via copy
    /// button + `textSelection(.enabled)` (the rendered substring is selectable
    /// but the clipboard button is the primary path for the full value).
    private var pubkeyDisplay: String {
        guard selfPubHex.count > 16 else { return selfPubHex }
        return String(selfPubHex.prefix(16)) + "…"
    }

    /// Resolve self pubkey from `IdentityService.ensureLocalIdentity` via the
    /// shared TeamKeystore root. Filesystem I/O — done once in `.task`.
    private func loadSelfPubHex() {
        do {
            let priv = try IdentityService.ensureLocalIdentity(at: TeamKeystore.defaultRoot())
            selfPubHex = priv.publicKey.rawRepresentation
                .map { String(format: "%02x", $0) }
                .joined()
        } catch {
            // Leave selfPubHex empty → "Generating identity…" placeholder.
            // Composition root logs identity errors elsewhere; UI just shows
            // a neutral state instead of crashing.
            selfPubHex = ""
        }
    }
}
