//
//  SendDirectMessageSheet.swift
//  Leaf
//
//  Track 5 / S4 — modal Send sheet for direct messages. Three template types
//  (Handoff/Task/Ping), text body, optional reply_to. Cross-post channels
//  (Slack/Linear) gated by per-provider scopes + channel/team pickers.
//
//  Track 5 / S6 T12 — adds interactive ChannelsPickerSection (Slack +
//  Linear cross-post), 🔓 privacy banner shown when any non-Leaf channel
//  is ON, per-channel status rows on `.sent`, and 1.5s auto-dismiss timing
//  on full success (manual [Done] on any cross-post failure — A9 timing).
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

    /// Composition root supplies these closures so the sheet stays
    /// SwiftUI-pure (no actor dependencies, no OAuth services imported).
    /// In dev / non-LeafCorePrivate builds they're no-ops; in production
    /// they bridge to SlackOAuthService.connect() / LinearUsersResolver.
    let onReauthorizeSlack: @MainActor () async -> Void
    let resolveLinearAssignee: @MainActor (String) async -> String?

    @State private var kind: DirectMessageKind = .ping
    @State private var bodyText: String = ""
    @State private var notify: Bool = true

    // S6 cross-post controls
    @State private var slackEnabled: Bool = false
    @State private var slackChannelID: String? = nil
    @State private var linearEnabled: Bool = false
    @State private var linearTeamID: String? = nil
    @State private var linearAssigneeID: String? = nil
    @State private var linearAssigneeNote: String? = nil
    /// Per-send idempotency key for Linear (A5 — Linear issueCreate dedupes
    /// on identical input UUIDs). Regenerated when user discards and reopens
    /// the sheet for a fresh send.
    @State private var linearIdempotencyKey: UUID = UUID()

    init(
        recipient: TeamMember,
        onReauthorizeSlack: @escaping @MainActor () async -> Void = {},
        resolveLinearAssignee: @escaping @MainActor (String) async -> String? = { _ in nil }
    ) {
        self.recipient = recipient
        self.onReauthorizeSlack = onReauthorizeSlack
        self.resolveLinearAssignee = resolveLinearAssignee
    }

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
        case .sent(_, let status, let crossPost):
            sentCard(status: status, crossPost: crossPost)
                .task {
                    // A9 timing — 1.5s auto-dismiss ONLY when every requested
                    // channel succeeded. Any failure → stay open; user reads
                    // status rows; [Done] button manually closes.
                    let allCrossOK = (crossPost.slack?.ok ?? true)
                        && (crossPost.linear?.ok ?? true)
                    if allCrossOK {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        // Re-check state — user might have hit [Done] already
                        // and we don't want to dismiss a sheet that's been
                        // reset for another send.
                        if case .sent = reader.state {
                            dismiss()
                        }
                    }
                }
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
                ChannelsPickerSection(
                    slackEnabled: $slackEnabled,
                    slackChannelID: $slackChannelID,
                    linearEnabled: $linearEnabled,
                    linearTeamID: $linearTeamID,
                    linearAssigneeID: $linearAssigneeID,
                    linearAssigneeNote: $linearAssigneeNote,
                    kind: kind,
                    recipientDisplayName: recipient.displayName,
                    onReauthorizeSlack: onReauthorizeSlack,
                    resolveLinearAssignee: resolveLinearAssignee
                )
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
            // A15 placeholder hint — Slack `@user` text doesn't auto-ping in
            // v1; tell users so they don't expect notification behavior.
            Text("Type @-mentions explicitly — they appear as text in Slack (no auto-ping in v1).")
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.tertiary)
        }
    }

    private var notifyToggle: some View {
        Toggle(isOn: $notify) {
            Text("Send push notification")
                .font(LeafType.body.small)
        }
    }

    private func sentCard(
        status: SentDirectMessage.PushDispatchStatus,
        crossPost: CrossPostStatuses
    ) -> some View {
        LeafCard(variant: .raised, padding: .generous) {
            VStack(alignment: .leading, spacing: LeafSpace.md) {
                CrossPostStatusRow.leaf(
                    recipientDisplayName: recipient.displayName,
                    pushStatus: status
                )
                if let slack = crossPost.slack {
                    CrossPostStatusRow.slack(slack)
                }
                if let linear = crossPost.linear {
                    CrossPostStatusRow.linear(linear)
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
                .disabled(sendDisabled)
            default:
                EmptyView()
            }
        }
    }

    private var sendDisabled: Bool {
        if bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        // Slack toggle ON requires a channel selection.
        if slackEnabled && (slackChannelID?.isEmpty ?? true) {
            return true
        }
        // Linear toggle ON requires a team selection (assignee optional).
        if linearEnabled && (linearTeamID?.isEmpty ?? true) {
            return true
        }
        return false
    }

    private func submit() async {
        // Capture immutable copies of the current toggle / picker state so a
        // late SwiftUI re-render mid-await doesn't see partial values.
        let slackRequest: SlackCrossPostRequest?
        if slackEnabled, let cid = slackChannelID, !cid.isEmpty {
            slackRequest = SlackCrossPostRequest(channelID: cid)
        } else {
            slackRequest = nil
        }

        let linearRequest: LinearCrossPostRequest?
        if linearEnabled, let tid = linearTeamID, !tid.isEmpty, kind == .task {
            linearRequest = LinearCrossPostRequest(
                teamID: tid,
                assigneeID: linearAssigneeID,
                idempotencyKey: linearIdempotencyKey,
                attachedEventRef: nil
            )
        } else {
            linearRequest = nil
        }

        await reader.send(
            recipientPubkeyHex: recipient.pubkeyHex,
            recipientMemberID: recipient.id,
            kind: kind,
            body: bodyText,
            notify: notify,
            crossPostSlack: slackRequest,
            crossPostLinear: linearRequest
        )
    }

    private func discardAndDismiss() {
        reader.reset()
        // Regenerate idempotency key so the next sheet open starts a fresh
        // Linear issue dedupe scope. Discarding and reopening should NEVER
        // collapse with a previous send.
        linearIdempotencyKey = UUID()
        dismiss()
    }
}
