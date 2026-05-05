//
//  GenerateInviteSheet.swift
//  Leaf
//
//  Phase 5.2.D — admin invite-generation sheet. State machine routed
//  through InviteOutboxReader. Step 1 (input pubkey hex) → Step 2 (token+OTP
//  copy + countdown). Discard / Revoke+Done close the sheet.
//

import SwiftUI
import AppKit
import LeafCore

struct GenerateInviteSheet: View {
    @Environment(InviteOutboxReader.self) private var reader
    @Environment(\.dismiss) private var dismiss
    @State private var pubkeyInput: String = ""

    private let hexRegex = /^[0-9a-fA-F]{64}$/

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header

            content

            Spacer(minLength: 0)
            footer
        }
        .padding(28)
        .frame(width: 560, height: 540)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("INVITE")
                .leafLabelStyle()
            Text("Generate invite")
                .font(.leafHeadline)
                .foregroundStyle(.leafInk)
        }
    }

    // MARK: - Content (state-routed)

    @ViewBuilder
    private var content: some View {
        switch reader.state {
        case .idle:
            step1(disabled: false)
        case .generating:
            step1(disabled: true)
            HStack { Spacer(); ProgressView(); Spacer() }
        case .ready(let outbound):
            step1(disabled: true)
            step2(outbound: outbound)
        case .error(let message):
            step1(disabled: false)
            Text(message)
                .font(.leafBody)
                .foregroundStyle(.red)
                .lineSpacing(3)
        }
    }

    // MARK: - Step 1

    private func step1(disabled: Bool) -> some View {
        GlassCard(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                Text("STEP 1 · INVITEE SHARES THEIR PUBKEY WITH YOU").leafLabelStyle()

                TextField("64-character hex", text: $pubkeyInput, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(2, reservesSpace: true)
                    .disabled(disabled)

                HStack {
                    Spacer()
                    Button("Generate invite") {
                        let trimmed = pubkeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        reader.generate(inviteePubkeyHex: trimmed)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(disabled || !isValidPubkey)
                }
            }
        }
    }

    // MARK: - Step 2

    private func step2(outbound: InviteOutbound) -> some View {
        GlassCard(padding: 20) {
            VStack(alignment: .leading, spacing: 16) {
                Text("STEP 2 · SEND TO INVITEE (Slack/Telegram)").leafLabelStyle()

                copyRow(label: "TOKEN", value: outbound.token)
                Divider().opacity(0.3)
                copyRow(label: "OTP", value: outbound.otp, displayOverride: formatOTP(outbound.otp))
                Divider().opacity(0.3)

                HStack {
                    Text(countdownText(expiresAtMs: outbound.expiresAtMs))
                        .font(.leafCaption)
                        .foregroundStyle(.leafInk.opacity(0.6))
                    Spacer()
                }
            }
        }
    }

    private func copyRow(label: String, value: String, displayOverride: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label).leafLabelStyle()
                Text(displayOverride ?? value)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.leafInk)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Discard") {
                reader.dismiss()
                dismiss()
            }
            .buttonStyle(.bordered)

            Spacer()

            if case .ready = reader.state {
                Button("Revoke + Done") {
                    reader.revokeAndDismiss()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Helpers

    private var isValidPubkey: Bool {
        let trimmed = pubkeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.wholeMatch(of: hexRegex) != nil
    }

    private func formatOTP(_ otp: String) -> String {
        guard otp.count == 6 else { return otp }
        let i = otp.index(otp.startIndex, offsetBy: 3)
        return "\(otp[..<i]) · \(otp[i...])"
    }

    private func countdownText(expiresAtMs: Int64) -> String {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let remainingSec = max(0, (expiresAtMs - nowMs) / 1000)
        let h = remainingSec / 3600
        let m = (remainingSec % 3600) / 60
        if h > 0 {
            return "Expires in \(h)h \(m)m"
        }
        return "Expires in \(m)m"
    }
}
