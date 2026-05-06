//
//  AcceptInviteSheet.swift
//  Leaf
//
//  Phase 5.2.E — invitee accept-invite sheet. State machine routed
//  through InviteAcceptReader. Two-step flow:
//   Step 1: invitee shares own pubkey hex (Copy) + pastes admin token →
//           "Fetch invite" → relay GET (one-shot consumes invite).
//   Step 2: blob in RAM → invitee enters OTP + display name → "Accept" →
//           local decode + DB write. Wrong OTP retried locally без re-fetch
//           до 5 раз; после — "Discard + ask admin" CTA surfaces.
//
//  Mirror GenerateInviteSheet (5.2.D) shape: header / state-routed content
//  ViewBuilder / footer.
//

import SwiftUI
import AppKit
import LeafCore

struct AcceptInviteSheet: View {
    @Environment(InviteAcceptReader.self) private var reader
    @Environment(OrgReader.self) private var orgReader
    @Environment(\.dismiss) private var dismiss

    @State private var tokenInput: String = ""
    @State private var otpInput: String = ""
    @State private var displayNameInput: String = ""
    @State private var myPubkeyHex: String = ""

    private let otpRegex = /^\d{6}$/

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            content
            Spacer(minLength: 0)
            footer
        }
        .padding(28)
        .frame(width: 560, height: 640)
        .onAppear { loadMyPubkey() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ACCEPT INVITE")
                .leafLabelStyle()
            Text("Join your team")
                .font(.leafHeadline)
                .foregroundStyle(.leafInk)
        }
    }

    // MARK: - Content (state-routed)

    @ViewBuilder
    private var content: some View {
        switch reader.state {
        case .idle:
            pubkeyShare
            tokenStep(disabled: false)
        case .fetching:
            pubkeyShare
            tokenStep(disabled: true)
            HStack { Spacer(); ProgressView(); Spacer() }
        case .otpEntry(_, let attempts):
            otpStep(attempts: attempts, disabled: false)
        case .accepting:
            otpStep(attempts: 0, disabled: true)
            HStack { Spacer(); ProgressView(); Spacer() }
        case .success(let orgName, let memberCount):
            successCard(orgName: orgName, memberCount: memberCount)
        case .error(let message, let recoverable):
            errorCard(message: message, recoverable: recoverable)
        }
    }

    // MARK: - Step 0 — share my pubkey

    private var pubkeyShare: some View {
        GlassCard(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                Text("STEP 1 · SHARE YOUR PUBKEY WITH ADMIN").leafLabelStyle()
                Text("Send this hex string to your admin (Slack/Telegram). They’ll use it to encrypt your invite.")
                    .font(.leafCaption)
                    .foregroundStyle(.leafInk.opacity(0.7))
                HStack(alignment: .firstTextBaseline) {
                    Text(myPubkeyHex.isEmpty ? "—" : myPubkeyHex)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.leafInk)
                        .textSelection(.enabled)
                        .lineLimit(2)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(myPubkeyHex, forType: .string)
                    }
                    .buttonStyle(.bordered)
                    .disabled(myPubkeyHex.isEmpty)
                }
            }
        }
    }

    // MARK: - Step 1 — paste token

    private func tokenStep(disabled: Bool) -> some View {
        GlassCard(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                Text("STEP 2 · PASTE INVITE TOKEN FROM ADMIN").leafLabelStyle()
                TextField("Token from admin (Slack/Telegram)", text: $tokenInput, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(2, reservesSpace: true)
                    .disabled(disabled)
                HStack {
                    Spacer()
                    Button("Fetch invite") {
                        let trimmed = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        reader.fetch(token: trimmed)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(disabled || trimmedToken.isEmpty)
                }
            }
        }
    }

    // MARK: - Step 2 — OTP + display name

    private func otpStep(attempts: Int, disabled: Bool) -> some View {
        GlassCard(padding: 20) {
            VStack(alignment: .leading, spacing: 16) {
                Text("STEP 3 · ENTER OTP + YOUR NAME").leafLabelStyle()
                Text("Invite fetched. Now enter the 6-digit OTP from admin and pick how you’ll show up to the team.")
                    .font(.leafCaption)
                    .foregroundStyle(.leafInk.opacity(0.7))

                VStack(alignment: .leading, spacing: 6) {
                    Text("OTP").leafLabelStyle()
                    TextField("123456", text: $otpInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .disabled(disabled)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("YOUR DISPLAY NAME").leafLabelStyle()
                    TextField("e.g. Bob", text: $displayNameInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.leafBody)
                        .disabled(disabled)
                }

                if attempts > 0 {
                    Text(attempts >= 5
                         ? "Too many wrong attempts. Discard and ask admin to send a new invite."
                         : "OTP didn’t match — try again (\(attempts)/5).")
                        .font(.leafCaption)
                        .foregroundStyle(.red)
                }

                HStack {
                    Spacer()
                    Button("Accept invite") {
                        let otp = otpInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        let dn = displayNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        reader.submitOTP(otp: otp, displayName: dn)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(disabled || !isValidOTP || trimmedDisplayName.isEmpty || attempts >= 5)
                }
            }
        }
    }

    // MARK: - Success

    private func successCard(orgName: String, memberCount: Int) -> some View {
        GlassCard(padding: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Joined \(orgName)", systemImage: "checkmark.circle.fill")
                    .font(.leafHeadline)
                    .foregroundStyle(.green)
                Text("You’re now part of a team with \(memberCount) member\(memberCount == 1 ? "" : "s"). The Organization and Team tabs are updated.")
                    .font(.leafBody)
                    .foregroundStyle(.leafInk.opacity(0.85))
                    .lineSpacing(3)
            }
        }
    }

    // MARK: - Error

    private func errorCard(message: String, recoverable: Bool) -> some View {
        GlassCard(padding: 24) {
            VStack(alignment: .leading, spacing: 16) {
                Label("Couldn’t accept invite", systemImage: "exclamationmark.triangle.fill")
                    .font(.leafBody.weight(.semibold))
                    .foregroundStyle(.red)
                Text(message)
                    .font(.leafBody)
                    .foregroundStyle(.leafInk)
                    .lineSpacing(3)
                if recoverable {
                    HStack {
                        Spacer()
                        Button("Try again") {
                            reader.discardAndReset()
                            tokenInput = ""
                            otpInput = ""
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    // MARK: - Footer

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
            } else if case .otpEntry(_, let attempts) = reader.state, attempts >= 5 {
                Button("Discard + ask admin") {
                    reader.discardAndReset()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Helpers

    private var trimmedToken: String {
        tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedDisplayName: String {
        displayNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValidOTP: Bool {
        let trimmed = otpInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.wholeMatch(of: otpRegex) != nil
    }

    private func loadMyPubkey() {
        do {
            myPubkeyHex = try reader.myPubkeyHex()
        } catch {
            myPubkeyHex = ""
        }
    }
}
