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
import AppKit
import LeafCore

struct GenerateInviteSheet: View {
    @Environment(InviteOutboxReader.self) private var reader
    @Environment(WorkspaceReader.self) private var workspaceReader
    @Environment(InviteURLHandler.self) private var urlHandler
    @Environment(\.dismiss) private var dismiss
    @State private var joinCodeInput: String = ""
    @State private var inputMode: InputMode = .paste
    /// Track 5 / S3 — opt-in OTP toggle. Default OFF. When ON, admin sees a separate
    /// 6-digit code that must be sent through a different channel from the link itself.
    @State private var requireOTP: Bool = false

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
            requireOTPToggle(disabled: false)
            if case .error(let m) = reader.state {
                LeafBanner(tone: .danger, title: "Couldn't generate invite", description: m)
            }
        case .generating:
            modePicker
            modeContent(disabled: true)
            requireOTPToggle(disabled: true)
            HStack { Spacer(); ProgressView(); Spacer() }
        case .ready(let outbound):
            readyOutput(outbound: outbound)
        }
    }

    private func requireOTPToggle(disabled: Bool) -> some View {
        LeafCard(variant: .raised, padding: .regular) {
            Toggle(isOn: $requireOTP) {
                VStack(alignment: .leading, spacing: LeafSpace.xs) {
                    Text("REQUIRE OTP").leafSectionLabel().foregroundStyle(LeafColor.text.tertiary)
                    Text("Adds a 6-digit code that must be sent through a separate channel.")
                        .font(LeafType.body.small)
                        .foregroundStyle(LeafColor.text.secondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(disabled)
            .onChange(of: requireOTP) { _, newValue in
                reader.requireOTP = newValue
            }
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

    @ViewBuilder
    private func readyOutput(outbound: InviteOutbound) -> some View {
        VStack(alignment: .leading, spacing: LeafSpace.lg) {
            LeafCard(variant: .raised, padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.lg) {
                    Text("SEND INVITE LINK").leafSectionLabel().foregroundStyle(LeafColor.text.tertiary)
                    Text(outbound.otp == nil
                         ? "Anyone with this link can join in the next 24 hours."
                         : "Send this link AND the 6-digit code separately (e.g. link via Slack, OTP via Telegram).")
                        .font(LeafType.body.small)
                        .foregroundStyle(LeafColor.text.secondary)

                    let url = outbound.url
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

            if let otp = outbound.otp {
                LeafCard(variant: .raised, padding: .regular) {
                    VStack(alignment: .leading, spacing: LeafSpace.md) {
                        Text("ONE-TIME CODE").leafSectionLabel().foregroundStyle(LeafColor.text.tertiary)
                        Text("Send this 6-digit code through a different channel than the link.")
                            .font(LeafType.body.small)
                            .foregroundStyle(LeafColor.text.secondary)
                        HStack {
                            Text(otp)
                                .font(LeafType.title.small)
                                .tracking(4)
                                .foregroundStyle(LeafColor.text.primary)
                                .textSelection(.enabled)
                            Spacer()
                            LeafButton("Copy OTP", variant: .secondary, size: .sm, action: {
                                let pb = NSPasteboard.general
                                pb.clearContents()
                                pb.setString(otp, forType: .string)
                            })
                        }
                    }
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
        if case .loaded(_, let active, _) = workspaceReader.state { return active.name }
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
