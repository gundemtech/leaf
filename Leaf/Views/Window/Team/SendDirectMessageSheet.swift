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
    /// T4 — tier gate. When `.canSendDM` is false, [Send] is disabled +
    /// UpgradeChip overlay shows above the form + clicking [Upgrade] opens
    /// UpgradeModal `.sheet`.
    @Environment(TierGateReader.self) private var tierGate
    /// T4 — composition-root waitlist closure for UpgradeModal.
    @Environment(\.submitToWaitlist) private var submitToWaitlist

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
    /// T4 — per-callsite UpgradeModal flag (NOT a WindowState global; mirrors
    /// WorkspaceCreateSheet pattern).
    @State private var showUpgrade: Bool = false

    /// AI Coworker P4 — "Draft with AI" sub-flow (handoff kind only). `topicText`
    /// is what the handoff is about; `draftProvenance` is set when an AI draft
    /// fills `bodyText` and is carried to the SEND-time M032 audit. It survives
    /// edits (an edited AI draft is still AI-originated team-egress) and is
    /// cleared on Discard or when the kind switches away from `.handoff`.
    @Environment(HandoffDraftReader.self) private var handoffReader
    @Environment(WindowState.self) private var windowState
    /// Exact-match CTA for the missing-key failure (pattern: AskLeafView).
    private static let missingKeyMessage = AIWorkAnswerer.message(for: .missingAPIKey)
    @State private var topicText: String = ""
    @State private var draftProvenance: HandoffProvenance? = nil
    /// AI-UI-3 — draft period (was fixed 7 days). Drives both the gather and
    /// the provenance period stamped into the M032 audit.
    @State private var draftPeriod: ReviewActivityInsights.ReviewActivityPeriod = .last7Days
    /// AI-UI-3 — escalation-in-draft consent step.
    @State private var showRedraftConsent: Bool = false

    init(
        recipient: TeamMember,
        initialKind: DirectMessageKind = .ping,
        initialTopic: String = "",
        onReauthorizeSlack: @escaping @MainActor () async -> Void = {},
        resolveLinearAssignee: @escaping @MainActor (String) async -> String? = { _ in nil }
    ) {
        self.recipient = recipient
        self.onReauthorizeSlack = onReauthorizeSlack
        self.resolveLinearAssignee = resolveLinearAssignee
        // AI-UI-3 — entry points pick the kind (chat [+] menu, Ask Leaf NL
        // suggestion) so the sheet no longer always opens on .ping.
        _kind = State(initialValue: initialKind)
        _topicText = State(initialValue: initialTopic)
    }

    var body: some View {
        LeafSheetLayout(title: "Send to \(recipient.displayName)", onDismiss: discardAndDismiss) {
            VStack(alignment: .leading, spacing: LeafSpace.xl) {
                // T4 — UpgradeChip when Free-tier blocks DM send. Form remains
                // visible so user sees what unlocking gets them; [Send] disabled.
                if !tierGate.canSendDM {
                    upgradeChip(message: "Direct messages require Leaf Team")
                }
                content
                Spacer(minLength: 0)
                footer
            }
        }
        .sheet(isPresented: $showUpgrade) {
            UpgradeModal(
                reason: .sendMessage,
                onDismiss: { showUpgrade = false },
                onSubmitEmail: { email in await submitToWaitlist(email) }
            )
        }
        // AI draft ready → fill the editable body + stash provenance for the
        // send-time audit. The user edits/approves the body before Send.
        .onChange(of: handoffReader.state) { _, newState in
            if case .drafted(let text, let provenance) = newState {
                bodyText = text
                draftProvenance = provenance
            }
        }
        // Switching away from Handoff clears the AI sub-flow so a Task/Ping send
        // never carries handoff provenance.
        .onChange(of: kind) { _, newKind in
            if newKind != .handoff {
                topicText = ""
                draftProvenance = nil
                showRedraftConsent = false
                handoffReader.reset()
            }
        }
        // AI-UI-3 — escalation-in-draft consent step. Period + topic are FROZEN
        // from the draft's provenance (review MEDIUM-3): details are added to
        // THIS draft, not whatever the live picker/topic field says now.
        .sheet(isPresented: $showRedraftConsent) {
            if let p = draftProvenance {
                HandoffRedraftConsentSheet(
                    recipientName: recipient.displayName,
                    topic: p.topicExcerpt,
                    period: DateInterval(
                        start: Date(timeIntervalSince1970: Double(p.periodStartMs) / 1000),
                        end: Date(timeIntervalSince1970: Double(p.periodEndMs) / 1000)))
            }
        }
        // The draft reader is an app-wide singleton; a swipe/Escape dismiss bypasses
        // discardAndDismiss. Reset on appear so a freshly-opened sheet never shows a
        // prior sheet's stale .drafting/.error/.drafted state (review MEDIUM).
        .onAppear { handoffReader.reset() }
    }

    // MARK: - T4 UpgradeChip

    @ViewBuilder
    private func upgradeChip(message: String) -> some View {
        HStack(spacing: LeafSpace.sm) {
            Image(systemName: "lock.fill")
                .foregroundStyle(LeafColor.status.warning)
            Text(message)
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.primary)
            Spacer()
            LeafButton("Upgrade", variant: .primary, size: .sm) {
                showUpgrade = true
            }
        }
        .padding(LeafSpace.sm)
        .background(LeafColor.status.warning.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.sm, style: .continuous))
    }

    @ViewBuilder
    private var content: some View {
        switch reader.state {
        case .idle:
            composeCard
        case .sending:
            HStack { Spacer(); ProgressView("Sending…"); Spacer() }
        case .sent(let messageID, let status, let crossPost):
            sentCard(status: status, crossPost: crossPost)
                .task {
                    // AI Coworker P4 (§8 п.4) — record the AI-assisted handoff
                    // SEND in the M032 reverse-audit (body-free; carries AI
                    // provenance + whether the body also left E2E via cross-post).
                    // Only when an AI draft fed this send (draftProvenance != nil);
                    // a purely manual handoff writes no row. Best-effort — the DM
                    // already sent, so a failed audit must not surface an error.
                    if let provenance = draftProvenance {
                        try? await HandoffAuditWriter().record(
                            messageID: messageID,
                            recipientMemberID: recipient.id,
                            provenance: provenance,
                            crosspostedSlack: slackEnabled,
                            crosspostedLinear: linearEnabled)
                    }
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
                if kind == .handoff {
                    draftWithAISection
                }
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

    // AI Coworker P4 — handoff-only "Draft with AI". Fills the editable body
    // below; the user reviews/edits before Send. The draft is built from the
    // user's OWN body-free facts via the same §8.1 boundary (HandoffDrafter).
    private var draftWithAISection: some View {
        VStack(alignment: .leading, spacing: LeafSpace.xs) {
            Text("TOPIC").leafSectionLabel().foregroundStyle(LeafColor.text.tertiary)
            HStack(spacing: LeafSpace.sm) {
                TextField("What's this handoff about? (e.g. auth refactor)", text: $topicText)
                    .textFieldStyle(.plain)
                    .font(LeafType.body.regular)
                    .padding(LeafSpace.xs)
                    .background(LeafColor.surface.canvas)
                    .clipShape(RoundedRectangle(cornerRadius: LeafRadius.sm))
                    .overlay(
                        RoundedRectangle(cornerRadius: LeafRadius.sm)
                            .stroke(LeafColor.border.subtle, lineWidth: 1))
                // AI-UI-3 — draft period picker (was fixed 7 days).
                Picker("Period", selection: $draftPeriod) {
                    Text("Today").tag(ReviewActivityInsights.ReviewActivityPeriod.today)
                    Text("Yesterday").tag(ReviewActivityInsights.ReviewActivityPeriod.yesterday)
                    Text("Last 7 days").tag(ReviewActivityInsights.ReviewActivityPeriod.last7Days)
                }
                .labelsHidden()
                .fixedSize()
                draftButton
            }
            if case .error(let message) = handoffReader.state {
                Text(message)
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.status.warning)
                if message == Self.missingKeyMessage {
                    Button("Open Settings") {
                        windowState.section = .settings
                        dismiss()
                    }
                }
            }
            // AI-UI-3 — provenance row + escalation-in-draft entry. Appears once
            // an AI draft fed the body (survives edits, mirrors draftProvenance).
            if let p = draftProvenance {
                HStack(spacing: LeafSpace.sm) {
                    Text("✨ Drafted from \(p.factCount) facts\(p.escalated ? " + details" : "")")
                        .font(LeafType.body.small)
                        .foregroundStyle(LeafColor.text.tertiary)
                    LeafButton("Add details (AI)…", variant: .secondary, size: .sm) {
                        showRedraftConsent = true
                    }
                    .disabled(handoffReader.state == .drafting)
                }
            }
            Text("Drafts from your own recent activity. Review before sending.")
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.tertiary)
        }
    }

    @ViewBuilder
    private var draftButton: some View {
        if handoffReader.state == .drafting {
            ProgressView().controlSize(.small)
        } else {
            LeafButton("Draft with AI", variant: .secondary, size: .sm) {
                Task {
                    await handoffReader.draft(
                        recipientName: recipient.displayName, topic: topicText,
                        period: draftPeriod.interval())
                }
            }
            .disabled(topicText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                .clipShape(RoundedRectangle(cornerRadius: LeafRadius.sm))
                .overlay(
                    RoundedRectangle(cornerRadius: LeafRadius.sm)
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
        // T4 — Free-tier blocks Send entirely. We keep the rest of the gates
        // active too so the disabled state is consistent across reasons.
        if !tierGate.canSendDM { return true }
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
        // T4 — defence in depth: if user somehow bypasses the disabled state
        // (Voice Control, automation), surface the upgrade modal instead of
        // actually firing the network send.
        guard tierGate.canSendDM else {
            await MainActor.run { showUpgrade = true }
            return
        }
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
        // AI Coworker P4 — clear the AI draft sub-flow so a reopened sheet starts
        // fresh and never carries stale handoff provenance into the next send.
        handoffReader.reset()
        topicText = ""
        draftProvenance = nil
        // Regenerate idempotency key so the next sheet open starts a fresh
        // Linear issue dedupe scope. Discarding and reopening should NEVER
        // collapse with a previous send.
        linearIdempotencyKey = UUID()
        dismiss()
    }
}
