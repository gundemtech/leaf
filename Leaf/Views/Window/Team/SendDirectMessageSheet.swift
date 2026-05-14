//
//  SendDirectMessageSheet.swift
//  Leaf
//
//  Track 5 / S4 — modal Send sheet for direct messages. Three template types
//  (Handoff/Task/Ping), text body, optional reply_to. Cross-post channels
//  (Slack/Linear) and attach event picker disabled with "Coming in S5/S6" hints.
//
//  Entry point: temporary [Send Direct Message] button per member row in
//  OrganizationView. Full Team UI integration lands in S7.
//

import SwiftUI
import LeafCore

struct SendDirectMessageSheet: View {
    let recipient: TeamMember

    @Environment(DirectMessageSendReader.self) private var reader
    @Environment(\.dismiss) private var dismiss
    @State private var kind: DirectMessageKind = .ping
    @State private var bodyText: String = ""
    @State private var notify: Bool = true

    var body: some View {
        LeafSheetLayout(title: "Send to \(recipient.displayName)", onDismiss: discardAndDismiss) {
            VStack(alignment: .leading, spacing: LeafSpace.xl) {
                content
                Spacer(minLength: 0)
                footer
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch reader.state {
        case .idle:
            composeCard
        case .sending:
            HStack { Spacer(); ProgressView("Sending…"); Spacer() }
        case .sent(_, let status):
            sentCard(status: status)
        case .error(let message):
            LeafBanner(
                tone: .danger,
                title: "Couldn't send",
                description: message,
                ctaTitle: "Try again",
                onCTA: { reader.reset() }
            )
        }
    }

    private var composeCard: some View {
        LeafCard(variant: .raised, padding: .regular) {
            VStack(alignment: .leading, spacing: LeafSpace.lg) {
                kindPicker
                bodyTextarea
                channelsHint
                notifyToggle
            }
        }
    }

    private var kindPicker: some View {
        VStack(alignment: .leading, spacing: LeafSpace.xs) {
            Text("TYPE").leafSectionLabel().foregroundStyle(LeafColor.text.tertiary)
            Picker("Type", selection: $kind) {
                Text("Handoff").tag(DirectMessageKind.handoff)
                Text("Task").tag(DirectMessageKind.task)
                Text("Ping").tag(DirectMessageKind.ping)
            }
            .pickerStyle(.segmented)
        }
    }

    private var bodyTextarea: some View {
        VStack(alignment: .leading, spacing: LeafSpace.xs) {
            Text("MESSAGE").leafSectionLabel().foregroundStyle(LeafColor.text.tertiary)
            TextEditor(text: $bodyText)
                .font(LeafType.body.regular)
                .frame(minHeight: 100, maxHeight: 200)
                .scrollContentBackground(.hidden)
                .padding(LeafSpace.xs)
                .background(LeafColor.surface.canvas)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(LeafColor.border.subtle, lineWidth: 1)
                )
        }
    }

    private var channelsHint: some View {
        VStack(alignment: .leading, spacing: LeafSpace.xs) {
            Text("CHANNELS").leafSectionLabel().foregroundStyle(LeafColor.text.tertiary)
            HStack(spacing: LeafSpace.sm) {
                Text("Leaf")
                    .font(LeafType.body.small)
                    .padding(.horizontal, LeafSpace.xs)
                    .padding(.vertical, 2)
                    .background(LeafColor.accent.primary.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Text("Slack — Coming in S6")
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.tertiary)
                Text("Linear — Coming in S6")
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.tertiary)
            }
        }
    }

    private var notifyToggle: some View {
        Toggle(isOn: $notify) {
            Text("Send push notification")
                .font(LeafType.body.small)
        }
    }

    private func sentCard(status: SentDirectMessage.PushDispatchStatus) -> some View {
        LeafCard(variant: .raised, padding: .generous) {
            VStack(alignment: .leading, spacing: LeafSpace.md) {
                LeafIconLabel(
                    icon: .asset(LeafIcons.status.successFill),
                    title: "Sent to \(recipient.displayName)",
                    iconTint: LeafColor.status.success,
                    titleStyle: LeafType.title.small
                )
                switch status {
                case .sent:
                    Text("Push delivered to recipient device.")
                        .font(LeafType.body.small)
                        .foregroundStyle(LeafColor.text.secondary)
                case .skipped:
                    Text("No push (notify off). Recipient will see on next inbox poll.")
                        .font(LeafType.body.small)
                        .foregroundStyle(LeafColor.text.secondary)
                case .failed(let reason):
                    Text("Push deferred: \(reason). Message persisted.")
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
            switch reader.state {
            case .sent:
                LeafButton("Done", variant: .primary, size: .md, action: discardAndDismiss)
            case .idle:
                LeafButton(
                    "Send",
                    variant: .primary,
                    size: .md,
                    action: { Task { await submit() } }
                )
                .disabled(bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            default:
                EmptyView()
            }
        }
    }

    private func submit() async {
        await reader.send(
            recipientPubkeyHex: recipient.pubkeyHex,
            recipientMemberID: recipient.id,
            kind: kind,
            body: bodyText,
            notify: notify
        )
    }

    private func discardAndDismiss() {
        reader.reset()
        dismiss()
    }
}
