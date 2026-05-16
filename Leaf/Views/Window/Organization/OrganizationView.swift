//
//  OrganizationView.swift
//  Track 2 / D4 — migrated to LeafSection chain + LeafCard.raised + LeafBanner.
//  Drop manual ORGANIZATION / Create-your-personal-org / etc leafLabelStyle headers
//  (LeafSection.title carries hierarchy). emptyContent carries 2 LeafSection blocks
//  (Organization create + Or-join-team). loadedContent carries 1 LeafSection
//  (Organization workspace metadata). error → LeafBanner.danger top.
//

import SwiftUI
import LeafCore

struct OrganizationView: View {
    @Environment(WorkspaceReader.self) private var reader
    @Environment(DirectMessageInboxReader.self) private var inboxReader
    @Environment(ActiveWorkspaceStore.self) private var activeStore
    @Environment(TeamEventBroadcastReader.self) private var broadcastReader
    @Environment(TeamEventMirrorReader.self) private var mirrorReader
    /// Track 5 / S6 T13 — composition refs for SendDirectMessageSheet closure wiring.
    @Environment(SlackOAuthService.self) private var slackOAuth
    @Environment(\.linearUsersResolver) private var linearUsersResolver
    @State private var nameInput: String = ""
    @State private var showingAcceptSheet: Bool = false
    @State private var sendSheetRecipient: SendRecipient?

    /// Identifiable wrapper for sheet(item:) — TeamMember is Hashable+Sendable but not Identifiable.
    private struct SendRecipient: Identifiable {
        let id: String  // matches TeamMember.id
        let member: TeamMember
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LeafSpace.xxl) {
                content
                Spacer(minLength: 0)
            }
            .padding(LeafSpace.xxl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { reader.refresh() }
        .task(id: activeStore.activeWorkspaceID) {
            // C2 fix — Track 5 / S4 Stage 6 review:
            // Foreground polling loop. SwiftUI `.task` cancels on view disappear or
            // ID change. We poll inbox every 30s while OrganizationView is on screen.
            // Background tick (5min) is a future scheduler refinement.
            guard let wid = activeStore.activeWorkspaceID else { return }
            await inboxReader.tick()
            // C1 fix — Track 5 / S5 Stage 6 review: broadcast + mirror +
            // daily retention prune scheduled in the same .task body so a
            // single workspace switch reinitializes all loops.
            await broadcastReader.tick(workspaceID: wid)
            await mirrorReader.tick(workspaceID: wid)
            await mirrorReader.pruneIfDueDaily()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { break }
                await inboxReader.tick()
                await broadcastReader.tick(workspaceID: wid)
                await mirrorReader.tick(workspaceID: wid)
                await mirrorReader.pruneIfDueDaily()
            }
        }
        .sheet(isPresented: $showingAcceptSheet) {
            AcceptInviteSheet()
        }
        .sheet(item: $sendSheetRecipient) { recipient in
            SendDirectMessageSheet(
                recipient: recipient.member,
                // Track 5 / S6 — wire real OAuth re-auth + assignee fuzzy resolve.
                onReauthorizeSlack: { @MainActor in
                    await slackOAuth.connect()
                },
                resolveLinearAssignee: { @MainActor displayName in
                    try? await linearUsersResolver.resolve(displayName: displayName)
                }
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        switch reader.state {
        case .loading:
            HStack { Spacer(); ProgressView(); Spacer() }
                .padding(.top, LeafSpace.xxxl)
        case .empty:
            emptyContent
        case .loaded(_, let active, let members):
            loadedContent(org: active, members: members)
        case .error(let message):
            errorContent(message: message)
        case .removedFromActiveWorkspace:
            // RootView preempts this state with RemovedFromTeamBanner.
            EmptyView()
        }
    }

    // MARK: - Empty: create CTA + or-join

    private var emptyContent: some View {
        VStack(alignment: .leading, spacing: LeafSpace.xxl) {
            LeafSection(
                title: "Organization",
                description: "Create your personal org. Solo for now — invite teammates after the org is set up. One org per device; the workspace name is just a label, you can change it later."
            ) {
                LeafCard(variant: .raised, padding: .regular) {
                    VStack(alignment: .leading, spacing: LeafSpace.md) {
                        Text("WORKSPACE NAME").leafSectionLabel().foregroundStyle(LeafColor.text.tertiary)
                        TextField("My Workspace", text: $nameInput)
                            .textFieldStyle(.roundedBorder)
                            .font(LeafType.body.regular)
                            .onSubmit(submit)
                        HStack {
                            Spacer()
                            LeafButton(
                                "Create personal org",
                                variant: .primary,
                                size: .md,
                                action: submit
                            )
                            .disabled(trimmedName.isEmpty)
                        }
                    }
                }
            }

            LeafSection(
                title: "Or join a team",
                description: "If a teammate invited you, accept the invite instead."
            ) {
                LeafButton(
                    "Accept invite",
                    variant: .secondary,
                    size: .md,
                    action: { showingAcceptSheet = true }
                )
            }
        }
    }

    // MARK: - Loaded: workspace card + members + inbox

    private func loadedContent(org: Workspace, members: [TeamMember]) -> some View {
        VStack(alignment: .leading, spacing: LeafSpace.xxl) {
            LeafSection(title: "Organization") {
                LeafCard(variant: .raised, padding: .regular) {
                    VStack(alignment: .leading, spacing: LeafSpace.md) {
                        Text(org.name)
                            .font(LeafType.title.medium)
                            .foregroundStyle(LeafColor.text.primary)
                        LeafDivider()
                        HStack(alignment: .firstTextBaseline) {
                            Text("Created")
                                .font(LeafType.body.regular)
                                .foregroundStyle(LeafColor.text.secondary)
                            Spacer()
                            Text(org.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(LeafType.mono.regular)
                                .foregroundStyle(LeafColor.text.primary)
                        }
                        LeafDivider()
                        Text("Single-org-per-device — to switch, wipe local data first.")
                            .font(LeafType.body.small)
                            .foregroundStyle(LeafColor.text.tertiary)
                    }
                }
            }

            // C3 fix — Track 5 / S4 Stage 6 review:
            // Temporary Send Direct Message entry per teammate row. Full Team UI
            // (sticky Send + unified feed) lands in S7 redesign. This is a
            // substrate-testing affordance only.
            if members.count > 1 {
                LeafSection(title: "Teammates") {
                    LeafCard(variant: .raised, padding: .regular) {
                        VStack(alignment: .leading, spacing: LeafSpace.md) {
                            ForEach(members.filter { $0.pubkeyHex != mySelfPubkey(members: members) }, id: \.id) { member in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(member.displayName)
                                            .font(LeafType.body.regular)
                                            .foregroundStyle(LeafColor.text.primary)
                                        Text(String(member.pubkeyHex.prefix(8)) + "…")
                                            .font(LeafType.mono.regular)
                                            .foregroundStyle(LeafColor.text.tertiary)
                                    }
                                    Spacer()
                                    LeafButton(
                                        "Send",
                                        variant: .secondary,
                                        size: .sm,
                                        action: { sendSheetRecipient = SendRecipient(id: member.id, member: member) }
                                    )
                                }
                                LeafDivider()
                            }
                        }
                    }
                }
            }

            // Recent inbound DMs — temporary placeholder; S7 replaces with full feed.
            if !inboxReader.recentMessages.isEmpty {
                LeafSection(title: "Recent direct messages") {
                    LeafCard(variant: .raised, padding: .regular) {
                        VStack(alignment: .leading, spacing: LeafSpace.md) {
                            ForEach(inboxReader.recentMessages.prefix(10), id: \.messageID) { row in
                                inboxRow(row)
                                if row.messageID != inboxReader.recentMessages.prefix(10).last?.messageID {
                                    LeafDivider()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func inboxRow(_ row: DirectMessageMirrorRow) -> some View {
        HStack(alignment: .top, spacing: LeafSpace.sm) {
            Image(systemName: iconName(for: row.kind))
                .foregroundStyle(LeafColor.accent.primary)
                .frame(width: 16, height: 16, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(row.senderDisplayName)
                        .font(LeafType.body.regular)
                        .foregroundStyle(LeafColor.text.primary)
                    Text("·").foregroundStyle(LeafColor.text.tertiary)
                    Text(directionLabel(row))
                        .font(LeafType.body.small)
                        .foregroundStyle(LeafColor.text.tertiary)
                    Spacer()
                    if row.direction == .inbound && row.readAtMs == nil {
                        Circle()
                            .fill(LeafColor.accent.primary)
                            .frame(width: 6, height: 6)
                    }
                }
                Text(row.body)
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func iconName(for kind: DirectMessageKind) -> String {
        switch kind {
        case .handoff: return "arrow.right.circle"
        case .task:    return "checklist"
        case .ping:    return "bell"
        }
    }

    private func directionLabel(_ row: DirectMessageMirrorRow) -> String {
        let kindLabel: String
        switch row.kind {
        case .handoff: kindLabel = "handoff"
        case .task:    kindLabel = "task"
        case .ping:    kindLabel = "ping"
        }
        return row.direction == .outbound ? "you sent \(kindLabel)" : "\(kindLabel)"
    }

    /// Best-effort self-pubkey resolution from member list — workspaces have one
    /// admin-created seed member; in S4 simple-test seed flows this is `members.first`.
    /// S7 will refine via `ActiveWorkspaceStore.selfMemberID`.
    private func mySelfPubkey(members: [TeamMember]) -> String {
        members.first(where: { $0.role == .admin })?.pubkeyHex ?? members.first?.pubkeyHex ?? ""
    }

    // MARK: - Error

    private func errorContent(message: String) -> some View {
        VStack(alignment: .leading, spacing: LeafSpace.lg) {
            LeafBanner(
                tone: .danger,
                title: "Couldn't load organization",
                description: message,
                ctaTitle: "Retry",
                onCTA: reader.refresh
            )
        }
    }

    // MARK: - Helpers

    private var trimmedName: String {
        nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        let name = trimmedName
        guard !name.isEmpty else { return }
        reader.createWorkspace(displayName: name)
    }
}
