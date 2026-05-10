//
//  GenerateInviteSheet.swift
//  Leaf
//
//  Phase 5.5.B — admin invite-generation. Two input modes:
//   1. Paste invitee Join code (clipboard auto-detect on appear; manual paste fallback).
//   2. Send "ask to join" template — admin first шлёт invitee app + onboarding hint.
//
//  Output: одна `leaf://invite/<token>#<otp>` deep-link с Copy / Mail / Messages кнопками + countdown.
//
//  Track 2 / D4 — migrated to LeafSheetLayout + LeafCard.raised + LeafTab inputMode picker.
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

    enum InputMode: String, CaseIterable, Identifiable, Hashable {
        case paste = "Paste Join code"
        case template = "Send template"
        var id: String { rawValue }
    }

    var body: some View {
        LeafSheetLayout(title: "Add a team member", onDismiss: discardAndDismiss) {
            VStack(alignment: .leading, spacing: LeafSpace.xl) {
                content
                Spacer(minLength: 0)
                footer
            }
        }
        .onAppear {
            if case .joinCode(let bytes) = urlHandler.probeClipboard(),
               let formatted = try? JoinCode.encode(pubkey: bytes) {
                joinCodeInput = formatted
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch reader.state {
        case .idle, .error:
            modePicker
            modeContent(disabled: false)
            if case .error(let m) = reader.state {
                LeafBanner(tone: .danger, title: "Couldn't generate invite", description: m)
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
        LeafTab(
            selection: $inputMode,
            tabs: InputMode.allCases,
            label: \.rawValue
        )
    }

    @ViewBuilder
    private func modeContent(disabled: Bool) -> some View {
        switch inputMode {
        case .paste:
            LeafCard(variant: .raised, padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.md) {
                    Text("PASTE INVITEE'S JOIN CODE").leafSectionLabel().foregroundStyle(LeafColor.text.tertiary)
                    TextField("ABCD-EFGH-…", text: $joinCodeInput, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .font(LeafType.mono.regular)
                        .lineLimit(2, reservesSpace: true)
                        .disabled(disabled)
                    HStack {
                        Spacer()
                        LeafButton(
                            "Generate invite",
                            variant: .primary,
                            size: .md,
                            action: { reader.generate(inviteeJoinCode: joinCodeInput) }
                        )
                        .disabled(disabled || joinCodeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        case .template:
            LeafCard(variant: .raised, padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.md) {
                    Text("SEND ASK-TO-JOIN TEMPLATE").leafSectionLabel().foregroundStyle(LeafColor.text.tertiary)
                    Text("Pick a teammate to invite. They'll install Leaf, copy their Join code, and send it back to you.")
                        .font(LeafType.body.small)
                        .foregroundStyle(LeafColor.text.secondary)
                    ShareTemplateButton(
                        templateBody: ShareTemplate.compose(.askToJoin(orgName: orgName)),
                        mailSubject: "Join Leaf team — \(orgName)"
                    )
                }
            }
        }
    }

    private func readyOutput(outbound: InviteOutbound) -> some View {
        LeafCard(variant: .raised, padding: .regular) {
            VStack(alignment: .leading, spacing: LeafSpace.lg) {
                Text("SEND INVITE LINK").leafSectionLabel().foregroundStyle(LeafColor.text.tertiary)
                Text("One link contains everything. Send via Mail / Messages or copy and paste anywhere.")
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.secondary)

                let url = InviteURL.compose(token: outbound.token, otp: outbound.otp)
                Text(url.absoluteString)
                    .font(LeafType.mono.small)
                    .foregroundStyle(LeafColor.text.primary)
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
                        .font(LeafType.body.small)
                        .foregroundStyle(LeafColor.text.tertiary)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            LeafButton("Discard", variant: .secondary, size: .md, action: discardAndDismiss)
            Spacer()
            if case .ready = reader.state {
                LeafButton(
                    "Revoke + Done",
                    variant: .primary,
                    size: .md,
                    action: {
                        reader.revokeAndDismiss()
                        dismiss()
                    }
                )
            }
        }
    }

    // MARK: - Helpers

    private func discardAndDismiss() {
        reader.dismiss()
        dismiss()
    }

    private var orgName: String {
        if case .loaded(let org, _) = orgReader.state { return org.name }
        return "your team"
    }

    private func inviteeDisplayNameHint() -> String {
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
