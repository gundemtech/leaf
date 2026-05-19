//
//  AcceptInviteSheet.swift
//  Leaf
//
//  Track 5 / S3 — invitee accept-invite sheet driven by InviteAcceptReader state machine:
//   .idle → paste-card OR clipboard auto-detect → .previewing → .joining →
//   (.joined / .otpPrompt / .error). Single-call acceptInvite under the hood.
//
//  Two input paths:
//   1. Deep-link `leaf://invite/...` → InviteURLHandler.handle dispatches reader.fetch.
//   2. Manual paste fallback (also handles clipboard auto-detect on sheet appear).
//

import SwiftUI
import AppKit
import LeafCore

struct AcceptInviteSheet: View {
    @Environment(InviteAcceptReader.self) private var reader
    @Environment(WorkspaceReader.self) private var workspaceReader
    @Environment(InviteURLHandler.self) private var urlHandler
    @Environment(\.dismiss) private var dismiss
    /// T4 — tier gate. When `.canAcceptInvite` is false, the [Join] button on
    /// preview / OTP cards is replaced with [Upgrade to accept] that opens
    /// UpgradeModal `.sheet`.
    @Environment(TierGateReader.self) private var tierGate
    @Environment(\.submitToWaitlist) private var submitToWaitlist
    @State private var pasteInput: String = ""
    @State private var otpInput: String = ""
    @State private var displayNameInput: String = ""
    /// T4 — per-callsite UpgradeModal flag.
    @State private var showUpgrade: Bool = false

    private let otpRegex = /^\d{6}$/

    var body: some View {
        LeafSheetLayout(title: "Join your team", onDismiss: discardAndDismiss) {
            VStack(alignment: .leading, spacing: LeafSpace.xl) {
                content
                Spacer(minLength: 0)
                footer
            }
        }
        .onAppear {
            displayNameInput = reader.savedDisplayName.isEmpty ? NSFullUserName() : reader.savedDisplayName
            autoDetectFromClipboard()
        }
        .sheet(isPresented: $showUpgrade) {
            UpgradeModal(
                reason: .acceptInvite,
                onDismiss: { showUpgrade = false },
                onSubmitEmail: { email in await submitToWaitlist(email) }
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        switch reader.state {
        case .idle:
            pasteCard(disabled: false)
        case .previewing(let preview, _):
            previewCard(preview: preview, disabled: false)
        case .joining:
            HStack { Spacer(); ProgressView("Joining…"); Spacer() }
        case .otpPrompt(let preview, _, let lastError):
            otpCard(preview: preview, lastError: lastError, disabled: false)
        case .joined(let orgName, let memberCount, let syncPending):
            successCard(orgName: orgName, memberCount: memberCount, syncPending: syncPending)
        case .error(let message, let recoverable, let retryURL):
            LeafBanner(
                tone: .danger,
                title: "Couldn't accept invite",
                description: message,
                ctaTitle: recoverable ? "Try again" : nil,
                onCTA: recoverable ? {
                    reader.reset()
                    if let url = retryURL { reader.fetch(inviteURL: url) }
                } : nil
            )
        }
    }

    private func pasteCard(disabled: Bool) -> some View {
        LeafCard(variant: .raised, padding: .regular) {
            VStack(alignment: .leading, spacing: LeafSpace.md) {
                Text("PASTE INVITE LINK").leafSectionLabel().foregroundStyle(LeafColor.text.tertiary)
                Text("Paste the `leaf://invite/...` link admin sent you. Or open the link itself — Leaf auto-fills.")
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.secondary)
                TextField("leaf://invite/...", text: $pasteInput, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(LeafType.mono.regular)
                    .lineLimit(2, reservesSpace: true)
                    .disabled(disabled)
                HStack {
                    Spacer()
                    LeafButton(
                        "Use link",
                        variant: .primary,
                        size: .md,
                        action: {
                            if let url = parseInviteURL(from: pasteInput) {
                                reader.fetch(inviteURL: url)
                            }
                        }
                    )
                    .disabled(disabled || pasteInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func previewCard(preview: URLPreview, disabled: Bool) -> some View {
        LeafCard(variant: .raised, padding: .regular) {
            VStack(alignment: .leading, spacing: LeafSpace.lg) {
                VStack(alignment: .leading, spacing: LeafSpace.xs) {
                    Text("JOIN TEAM").leafSectionLabel().foregroundStyle(LeafColor.text.tertiary)
                    Text("Join \"\(preview.workspaceName)\" team?")
                        .font(LeafType.title.small)
                        .foregroundStyle(LeafColor.text.primary)
                    Text("Inviter: \(preview.adminPubkeyHex.prefix(8))… (admin)")
                        .font(LeafType.body.small)
                        .foregroundStyle(LeafColor.text.secondary)
                }

                VStack(alignment: .leading, spacing: LeafSpace.xs) {
                    Text("YOUR DISPLAY NAME").leafSectionLabel().foregroundStyle(LeafColor.text.tertiary)
                    TextField("e.g. Sasha", text: $displayNameInput)
                        .textFieldStyle(.roundedBorder)
                        .font(LeafType.body.regular)
                        .disabled(disabled)
                }

                HStack {
                    Spacer()
                    // T4 — when Free-tier blocks acceptance, swap [Join team]
                    // for [Upgrade to accept] so the user sees what unlocking gets them.
                    if tierGate.canAcceptInvite {
                        LeafButton(
                            "Join team",
                            variant: .primary,
                            size: .md,
                            action: {
                                // S8 review B-Imp-2 — defence-in-depth: re-check tier in
                                // the action handler to close the render→tap race window
                                // (UserDefaults `tier` flip via `defaults write` + KVO
                                // broadcast could land between body evaluation and Button
                                // dispatch). Mirrors WorkspaceCreateSheet.createIfValid +
                                // SendDirectMessageSheet.submit defence pattern.
                                guard tierGate.canAcceptInvite else {
                                    showUpgrade = true
                                    return
                                }
                                let dn = displayNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                reader.join(displayName: dn, otp: nil)
                            }
                        )
                        .disabled(disabled || displayNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else {
                        LeafButton(
                            "Upgrade to accept",
                            variant: .primary,
                            size: .md,
                            icon: .system("lock.fill"),
                            action: { showUpgrade = true }
                        )
                    }
                }
            }
        }
    }

    private func otpCard(preview: URLPreview, lastError: String?, disabled: Bool) -> some View {
        LeafCard(variant: .raised, padding: .regular) {
            VStack(alignment: .leading, spacing: LeafSpace.lg) {
                VStack(alignment: .leading, spacing: LeafSpace.xs) {
                    Text("VERIFY + JOIN").leafSectionLabel().foregroundStyle(LeafColor.text.tertiary)
                    Text("Join \"\(preview.workspaceName)\" team?")
                        .font(LeafType.body.regular)
                    Text("Enter the 6-digit code from the inviter (sent through a separate channel).")
                        .font(LeafType.body.small)
                        .foregroundStyle(LeafColor.text.secondary)
                }

                VStack(alignment: .leading, spacing: LeafSpace.xs) {
                    Text("VERIFICATION CODE").leafSectionLabel().foregroundStyle(LeafColor.text.tertiary)
                    TextField("123456", text: $otpInput)
                        .textFieldStyle(.roundedBorder)
                        .font(LeafType.mono.regular)
                        .disabled(disabled)
                }

                VStack(alignment: .leading, spacing: LeafSpace.xs) {
                    Text("YOUR DISPLAY NAME").leafSectionLabel().foregroundStyle(LeafColor.text.tertiary)
                    TextField("e.g. Sasha", text: $displayNameInput)
                        .textFieldStyle(.roundedBorder)
                        .font(LeafType.body.regular)
                        .disabled(disabled)
                }

                if let msg = lastError {
                    Text(msg)
                        .font(LeafType.body.small)
                        .foregroundStyle(LeafColor.status.danger)
                }

                HStack {
                    Spacer()
                    // T4 — same Upgrade button swap as previewCard above.
                    if tierGate.canAcceptInvite {
                        LeafButton(
                            "Join team",
                            variant: .primary,
                            size: .md,
                            action: {
                                let otp = otpInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                let dn = displayNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                reader.join(displayName: dn, otp: otp)
                            }
                        )
                        .disabled(disabled || !isValidOTP || displayNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else {
                        LeafButton(
                            "Upgrade to accept",
                            variant: .primary,
                            size: .md,
                            icon: .system("lock.fill"),
                            action: { showUpgrade = true }
                        )
                    }
                }
            }
        }
    }

    private func successCard(orgName: String, memberCount: Int, syncPending: Bool) -> some View {
        LeafCard(variant: .raised, padding: .generous) {
            VStack(alignment: .leading, spacing: LeafSpace.md) {
                LeafIconLabel(
                    icon: .asset(LeafIcons.status.successFill),
                    title: "Joined \(orgName)",
                    iconTint: LeafColor.status.success,
                    titleStyle: LeafType.title.small
                )
                Text("You're now part of a team with \(memberCount) member\(memberCount == 1 ? "" : "s").")
                    .font(LeafType.body.regular)
                    .foregroundStyle(LeafColor.text.primary)
                if syncPending {
                    Text("Membership sync pending — admin will see you shortly.")
                        .font(LeafType.body.small)
                        .foregroundStyle(LeafColor.text.secondary)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            LeafButton("Discard", variant: .secondary, size: .md, action: discardAndDismiss)
            Spacer()
            if case .joined = reader.state {
                LeafButton(
                    "Done",
                    variant: .primary,
                    size: .md,
                    action: {
                        workspaceReader.refresh()
                        reader.reset()
                        dismiss()
                    }
                )
            } else if case .error(_, let recoverable, _) = reader.state, !recoverable {
                LeafButton("Close", variant: .primary, size: .md, action: discardAndDismiss)
            }
        }
    }

    // MARK: - Helpers

    private func discardAndDismiss() {
        reader.reset()
        dismiss()
    }

    private func autoDetectFromClipboard() {
        if case .inviteURL(let url) = urlHandler.probeClipboard() {
            reader.fetch(inviteURL: url)
        }
    }

    private func parseInviteURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { return nil }
        if case .success = InviteURL.parse(url) { return url }
        return nil
    }

    private var isValidOTP: Bool {
        let trimmed = otpInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.wholeMatch(of: otpRegex) != nil
    }
}
