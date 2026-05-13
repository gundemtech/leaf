//
//  AcceptInviteSheet.swift
//  Leaf
//
//  Phase 5.5.B — invitee accept-invite sheet. Three input paths converge на InviteAcceptReader:
//   1. Deep-link `leaf://invite/...` clicked while sheet is open → urlHandler.handle dispatches fetch.
//   2. Sheet auto-detect on appear: probeClipboard → inviteURL → fetch(inviteURL:).
//   3. Manual paste fallback (юзер вставляет deep-link / token text).
//  OTP auto-prefills из URL fragment если deep-link path; иначе требует input.
//
//  Track 2 / D4 — migrated to LeafSheetLayout + LeafCard.raised + LeafBanner. State machine
//  + 3 input paths preserved 1:1.
//

import SwiftUI
import AppKit
import LeafCore

struct AcceptInviteSheet: View {
    @Environment(InviteAcceptReader.self) private var reader
    @Environment(WorkspaceReader.self) private var workspaceReader
    @Environment(InviteURLHandler.self) private var urlHandler
    @Environment(\.dismiss) private var dismiss
    @State private var pasteInput: String = ""
    @State private var otpInput: String = ""
    @State private var displayNameInput: String = ""

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
        .onChange(of: reader.state) { _, newState in
            if case .otpEntry(_, _, let prefill?) = newState, otpInput.isEmpty {
                otpInput = prefill
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch reader.state {
        case .idle:
            pasteCard(disabled: false)
        case .fetching:
            pasteCard(disabled: true)
            HStack { Spacer(); ProgressView(); Spacer() }
        case .otpEntry(_, let attempts, _):
            otpCard(attempts: attempts, disabled: false)
        case .accepting:
            otpCard(attempts: 0, disabled: true)
            HStack { Spacer(); ProgressView(); Spacer() }
        case .success(let orgName, let memberCount):
            successCard(orgName: orgName, memberCount: memberCount)
        case .error(let message, let recoverable):
            LeafBanner(
                tone: .danger,
                title: "Couldn't accept invite",
                description: message,
                ctaTitle: recoverable ? "Try again" : nil,
                onCTA: recoverable ? {
                    reader.discardAndReset()
                    pasteInput = ""
                    otpInput = ""
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
                            } else {
                                let trimmed = pasteInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmed.isEmpty { reader.fetch(token: trimmed) }
                            }
                        }
                    )
                    .disabled(disabled || pasteInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func otpCard(attempts: Int, disabled: Bool) -> some View {
        LeafCard(variant: .raised, padding: .regular) {
            VStack(alignment: .leading, spacing: LeafSpace.lg) {
                Text("VERIFY + JOIN").leafSectionLabel().foregroundStyle(LeafColor.text.tertiary)
                Text("Enter the 6-digit verification code from admin (or auto-filled from invite link).")
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.secondary)

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

                if attempts > 0 {
                    Text(attempts >= 5
                         ? "Too many wrong codes. Discard and ask admin to send a new link."
                         : "Code didn't match — try again (\(attempts)/5).")
                        .font(LeafType.body.small)
                        .foregroundStyle(LeafColor.status.danger)
                }

                HStack {
                    Spacer()
                    LeafButton(
                        "Join team",
                        variant: .primary,
                        size: .md,
                        action: {
                            let otp = otpInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            let dn = displayNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            reader.submitOTP(otp: otp, displayName: dn)
                        }
                    )
                    .disabled(disabled || !isValidOTP || displayNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attempts >= 5)
                }
            }
        }
    }

    private func successCard(orgName: String, memberCount: Int) -> some View {
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
            }
        }
    }

    private var footer: some View {
        HStack {
            LeafButton("Discard", variant: .secondary, size: .md, action: discardAndDismiss)
            Spacer()
            if case .success = reader.state {
                LeafButton(
                    "Done",
                    variant: .primary,
                    size: .md,
                    action: {
                        workspaceReader.refresh()
                        reader.discardAndReset()
                        dismiss()
                    }
                )
            } else if case .error(_, let recoverable) = reader.state, !recoverable {
                LeafButton("Close", variant: .primary, size: .md, action: discardAndDismiss)
            } else if case .otpEntry(_, let attempts, _) = reader.state, attempts >= 5 {
                LeafButton("Discard + ask admin", variant: .primary, size: .md, action: discardAndDismiss)
            }
        }
    }

    // MARK: - Helpers

    private func discardAndDismiss() {
        reader.discardAndReset()
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
