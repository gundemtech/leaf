//
//  AcceptInviteSheet.swift
//  Leaf
//
//  Phase 5.5.B — invitee accept-invite. Three input paths converge на InviteAcceptReader:
//   1. Deep-link `leaf://invite/...` clicked while sheet is open → urlHandler.handle dispatches fetch.
//   2. Sheet auto-detect on appear: probeClipboard → inviteURL → fetch(inviteURL:).
//   3. Manual paste fallback (юзер вставляет deep-link / token text).
//  OTP auto-prefills из URL fragment если deep-link path; иначе требует input.
//

import SwiftUI
import AppKit
import LeafCore

struct AcceptInviteSheet: View {
    @Environment(InviteAcceptReader.self) private var reader
    @Environment(OrgReader.self) private var orgReader
    @Environment(InviteURLHandler.self) private var urlHandler
    @Environment(\.dismiss) private var dismiss
    @State private var pasteInput: String = ""
    @State private var otpInput: String = ""
    @State private var displayNameInput: String = ""

    private let otpRegex = /^\d{6}$/

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            content
            Spacer(minLength: 0)
            footer
        }
        .padding(28)
        .frame(width: 560, height: 600)
        .onAppear {
            displayNameInput = reader.savedDisplayName.isEmpty ? NSFullUserName() : reader.savedDisplayName
            autoDetectFromClipboard()
        }
        .onChange(of: reader.state) { _, newState in
            // Auto-prefill OTP textfield если reader пришёл в otpEntry с prefill.
            if case .otpEntry(_, _, let prefill?) = newState, otpInput.isEmpty {
                otpInput = prefill
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ACCEPT INVITE").leafLabelStyle()
            Text("Join your team").font(.leafHeadline).foregroundStyle(.leafInk)
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
            errorCard(message: message, recoverable: recoverable)
        }
    }

    private func pasteCard(disabled: Bool) -> some View {
        GlassCard(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                Text("PASTE INVITE LINK").leafLabelStyle()
                Text("Paste the `leaf://invite/...` link admin sent you. Or open the link itself — Leaf auto-fills.")
                    .font(.leafCaption).foregroundStyle(.leafInk.opacity(0.7))
                TextField("leaf://invite/...", text: $pasteInput, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(2, reservesSpace: true)
                    .disabled(disabled)
                HStack {
                    Spacer()
                    Button("Use link") {
                        if let url = parseInviteURL(from: pasteInput) {
                            reader.fetch(inviteURL: url)
                        } else {
                            // Fallback: plain token (legacy alpha.10/11 path) — still supported via fetch(token:).
                            let trimmed = pasteInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty { reader.fetch(token: trimmed) }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(disabled || pasteInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func otpCard(attempts: Int, disabled: Bool) -> some View {
        GlassCard(padding: 20) {
            VStack(alignment: .leading, spacing: 16) {
                Text("VERIFY + JOIN").leafLabelStyle()
                Text("Enter the 6-digit verification code from admin (or auto-filled from invite link).")
                    .font(.leafCaption).foregroundStyle(.leafInk.opacity(0.7))

                VStack(alignment: .leading, spacing: 6) {
                    Text("VERIFICATION CODE").leafLabelStyle()
                    TextField("123456", text: $otpInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .disabled(disabled)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("YOUR DISPLAY NAME").leafLabelStyle()
                    TextField("e.g. Sasha", text: $displayNameInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.leafBody)
                        .disabled(disabled)
                }

                if attempts > 0 {
                    Text(attempts >= 5
                         ? "Too many wrong codes. Discard and ask admin to send a new link."
                         : "Code didn't match — try again (\(attempts)/5).")
                        .font(.leafCaption).foregroundStyle(.red)
                }

                HStack {
                    Spacer()
                    Button("Join team") {
                        let otp = otpInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        let dn = displayNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        reader.submitOTP(otp: otp, displayName: dn)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(disabled || !isValidOTP || displayNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attempts >= 5)
                }
            }
        }
    }

    private func successCard(orgName: String, memberCount: Int) -> some View {
        GlassCard(padding: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Joined \(orgName)", image: LeafIcons.status.successFill)
                    .font(.leafHeadline).foregroundStyle(.green)
                Text("You're now part of a team with \(memberCount) member\(memberCount == 1 ? "" : "s").")
                    .font(.leafBody).foregroundStyle(.leafInk.opacity(0.85)).lineSpacing(3)
            }
        }
    }

    private func errorCard(message: String, recoverable: Bool) -> some View {
        GlassCard(padding: 24) {
            VStack(alignment: .leading, spacing: 16) {
                Label("Couldn't accept invite", image: LeafIcons.status.warningFill)
                    .font(.leafBody.weight(.semibold)).foregroundStyle(.red)
                Text(message).font(.leafBody).foregroundStyle(.leafInk).lineSpacing(3)
                if recoverable {
                    HStack {
                        Spacer()
                        Button("Try again") {
                            reader.discardAndReset()
                            pasteInput = ""
                            otpInput = ""
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Discard") {
                reader.discardAndReset()
                dismiss()
            }
            .buttonStyle(.bordered)
            Spacer()
            if case .success = reader.state {
                Button("Done") {
                    orgReader.refresh()
                    reader.discardAndReset()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            } else if case .error(_, let recoverable) = reader.state, !recoverable {
                Button("Close") {
                    reader.discardAndReset()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            } else if case .otpEntry(_, let attempts, _) = reader.state, attempts >= 5 {
                Button("Discard + ask admin") {
                    reader.discardAndReset()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Helpers

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
