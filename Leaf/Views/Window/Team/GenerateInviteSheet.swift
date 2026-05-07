//
//  GenerateInviteSheet.swift
//  Leaf
//
//  Phase 5.5.B — admin invite-generation. Two input modes:
//   1. Paste invitee Join code (clipboard auto-detect on appear; manual paste fallback).
//   2. Send "ask to join" template — admin first шлёт invitee app + onboarding hint, ждёт Join code в clipboard.
//
//  Output: одна `leaf://invite/<token>#<otp>` deep-link с Copy / Mail / Messages кнопками + countdown.
//

import SwiftUI
import LeafCore

struct GenerateInviteSheet: View {
    @Environment(InviteOutboxReader.self) private var reader
    @Environment(OrgReader.self) private var orgReader
    @Environment(InviteURLHandler.self) private var urlHandler
    @Environment(\.dismiss) private var dismiss
    @State private var joinCodeInput: String = ""
    @State private var inputMode: InputMode = .paste

    enum InputMode: String, CaseIterable, Identifiable {
        case paste = "Paste Join code"
        case template = "Send template"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            content
            Spacer(minLength: 0)
            footer
        }
        .padding(28)
        .frame(width: 560, height: 580)
        .onAppear {
            // Auto-detect Join code в clipboard. Re-encode bytes из match → formatted display
            // (single pasteboard read, no second .string lookup).
            if case .joinCode(let bytes) = urlHandler.probeClipboard(),
               let formatted = try? JoinCode.encode(pubkey: bytes) {
                joinCodeInput = formatted
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("INVITE").leafLabelStyle()
            Text("Add a team member").font(.leafHeadline).foregroundStyle(.leafInk)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch reader.state {
        case .idle, .error:
            modePicker
            modeContent(disabled: false)
            if case .error(let m) = reader.state {
                Text(m).font(.leafBody).foregroundStyle(.red).lineSpacing(3)
            }
        case .generating:
            modePicker
            modeContent(disabled: true)
            HStack { Spacer(); ProgressView(); Spacer() }
        case .ready(let outbound):
            readyOutput(outbound: outbound)
        }
    }

    private var modePicker: some View {
        Picker("", selection: $inputMode) {
            ForEach(InputMode.allCases) { m in Text(m.rawValue).tag(m) }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private func modeContent(disabled: Bool) -> some View {
        switch inputMode {
        case .paste:
            GlassCard(padding: 20) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("PASTE INVITEE'S JOIN CODE").leafLabelStyle()
                    TextField("ABCD-EFGH-…", text: $joinCodeInput, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(2, reservesSpace: true)
                        .disabled(disabled)
                    HStack {
                        Spacer()
                        Button("Generate invite") {
                            reader.generate(inviteeJoinCode: joinCodeInput)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(disabled || joinCodeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        case .template:
            GlassCard(padding: 20) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("SEND ASK-TO-JOIN TEMPLATE").leafLabelStyle()
                    Text("Pick a teammate to invite. They'll install Leaf, copy their Join code, and send it back to you.")
                        .font(.leafCaption).foregroundStyle(.leafInk.opacity(0.7))
                    ShareTemplateButton(
                        templateBody: ShareTemplate.compose(.askToJoin(orgName: orgName)),
                        mailSubject: "Join Leaf team — \(orgName)"
                    )
                }
            }
        }
    }

    private func readyOutput(outbound: InviteOutbound) -> some View {
        GlassCard(padding: 20) {
            VStack(alignment: .leading, spacing: 16) {
                Text("SEND INVITE LINK").leafLabelStyle()
                Text("One link contains everything. Send via Mail / Messages or copy and paste anywhere.")
                    .font(.leafCaption).foregroundStyle(.leafInk.opacity(0.7))

                let url = InviteURL.compose(token: outbound.token, otp: outbound.otp)
                Text(url.absoluteString)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.leafInk)
                    .textSelection(.enabled)
                    .lineLimit(3)

                ShareTemplateButton(
                    templateBody: ShareTemplate.compose(.adminShare(
                        displayName: inviteeDisplayNameHint(),
                        inviteURL: url
                    )),
                    mailSubject: "Your Leaf invite link"
                )

                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(countdownText(expiresAtMs: outbound.expiresAtMs, now: ctx.date))
                        .font(.leafCaption).foregroundStyle(.leafInk.opacity(0.6))
                }
            }
        }
    }

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

    private var orgName: String {
        if case .loaded(let org, _) = orgReader.state { return org.name }
        return "your team"
    }

    private func inviteeDisplayNameHint() -> String {
        // Admin sheet не знает invitee display name на этапе generation (paste-Join-code path
        // не несёт имя). Empty → ShareTemplate.adminShare свернёт на neutral greeting "Привет!".
        // 5.5.C surface name hint когда pending_invites.inviteeDisplayNameHint заполнен.
        return ""
    }

    private func countdownText(expiresAtMs: Int64, now: Date = Date()) -> String {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let remainingSec = max(0, (expiresAtMs - nowMs) / 1000)
        let h = remainingSec / 3600
        let m = (remainingSec % 3600) / 60
        let s = remainingSec % 60
        if h > 0 { return "Expires in \(h)h \(m)m" }
        if m > 0 { return "Expires in \(m)m \(s)s" }
        return remainingSec > 0 ? "Expires in \(s)s" : "Expired"
    }
}
