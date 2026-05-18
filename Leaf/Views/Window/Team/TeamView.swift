//
//  TeamView.swift
//  Track 5 / S7 G.2-G.5 — Unified Team feed layout.
//
//  Replaces Track 2 / D3 adaptive-grid-of-members with the new feed structure:
//
//    ┌── toolbar: name · N members · [+ Send] ⌘N ───────────────────────────┐
//    ├── members pill-row (horizontal scroll) ────────────────────────────────┤
//    ├── LeafFilterChips (All · DM · Tasks · Decisions · Blockers · More…) ───┤
//    └── feed body placeholder (G.6-G.11 dispatch fills in) ─────────────────┘
//
//  Environment dependencies:
//    Already wired (S2/S4/S5/S6):
//      WorkspaceReader, ActiveWorkspaceStore, DirectMessageInboxReader,
//      TeamEventMirrorReader, SlackOAuthService, \.linearUsersResolver
//    Phase H wires these new ones:
//      TeamFeedReader, FeedFilterStore, CrossPostLogReader
//
//  Phase H gap: @Environment(TeamFeedReader.self) and
//  @Environment(FeedFilterStore.self) will crash at runtime (not compile-time)
//  if not injected. Phase H composition root wires them. Until then the app
//  must not navigate to TeamView in a test run without the H injection.
//
//  Send entry:
//    • Tapping a member pill opens SendDirectMessageSheet for that member.
//    • [+ Send] toolbar button (G.6 dispatch will wire full recipient-picker).
//
//  S6 closure-injection pattern preserved 1:1 from OrganizationView:
//    • onReauthorizeSlack  — SlackOAuthService.connect()
//    • resolveLinearAssignee — LinearUsersResolver.resolve(displayName:)
//

import CryptoKit
import SwiftUI
import LeafCore

struct TeamView: View {

    // MARK: - Environment (S2/S4/S5/S6 — already in composition root)

    @Environment(WorkspaceReader.self)          private var workspaceReader
    @Environment(ActiveWorkspaceStore.self)     private var activeWorkspaceStore
    @Environment(DirectMessageInboxReader.self) private var inboxReader
    @Environment(TeamEventMirrorReader.self)    private var teamEventMirrorReader
    // S6 closure providers (identical wiring pattern to OrganizationView).
    @Environment(SlackOAuthService.self)        private var slackOAuth
    @Environment(\.linearUsersResolver)         private var linearUsersResolver

    // MARK: - Phase H: new environment readers
    //
    // These will be injected by Phase H composition root.
    // See LeafApp.swift — Phase H adds:
    //   .environment(teamFeedReader)
    //   .environment(feedFilterStore)
    // Until Phase H ships, navigating to TeamView crashes with:
    //   "No Observable of type TeamFeedReader found. A View.environment(_:) for
    //    TeamFeedReader may be missing as an ancestor of this view."

    @Environment(TeamFeedReader.self)  private var teamFeedReader
    @Environment(FeedFilterStore.self) private var feedFilterStore

    // MARK: - Local sheet state

    @State private var sendSheetRecipient: SendRecipient? = nil

    /// Identifiable wrapper for sheet(item:). TeamMember is Hashable+Sendable but
    /// not Identifiable; wrap its id + member ref.
    private struct SendRecipient: Identifiable {
        let id: String       // matches TeamMember.id
        let member: TeamMember
    }

    // MARK: - Body

    var body: some View {
        Group {
            switch workspaceReader.state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .empty:
                emptyStatePlaceholder

            case .loaded(_, let active, let members):
                loadedContent(active: active, members: members)

            case .error(let message):
                errorContent(message: message)

            case .removedFromActiveWorkspace:
                // RootView preempts with RemovedFromTeamBanner.
                EmptyView()
            }
        }
        // S6 closure-injection pattern — preserved 1:1 from OrganizationView.
        .sheet(item: $sendSheetRecipient) { r in
            SendDirectMessageSheet(
                recipient: r.member,
                onReauthorizeSlack: { @MainActor in
                    await slackOAuth.connect()
                },
                resolveLinearAssignee: { @MainActor displayName in
                    try? await linearUsersResolver.resolve(displayName: displayName)
                }
            )
        }
        // Restore persisted filter selection + trigger initial feed load when
        // the active workspace changes.
        .task(id: activeWorkspaceStore.activeWorkspaceID) {
            guard let wid = activeWorkspaceStore.activeWorkspaceID else { return }
            feedFilterStore.loadForWorkspace(wid)
            await teamFeedReader.loadInitial(
                workspaceID: wid,
                filters: feedFilterStore.selected,
                selfPubkeyHex: selfPubkeyHex()
            )
        }
        // Re-fetch when filter chip selection changes.
        .onChange(of: feedFilterStore.selected) { _, newFilters in
            guard let wid = activeWorkspaceStore.activeWorkspaceID else { return }
            Task {
                await teamFeedReader.refresh(
                    workspaceID: wid,
                    filters: newFilters,
                    selfPubkeyHex: selfPubkeyHex()
                )
            }
        }
    }

    // MARK: - G.2 Loaded content

    @ViewBuilder
    private func loadedContent(active: Workspace, members: [TeamMember]) -> some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            // G.3 — Toolbar: workspace name + member count + [+ Send] button
            toolbar(active: active, memberCount: members.count)
            // G.4 — Horizontal members pill-row (tap opens SendDirectMessageSheet)
            membersPillRow(members: members)
            // G.5 — Filter chips (All / DM / Open Tasks / Decisions / Blockers / More…)
            FeedFilterChipsBindable(store: feedFilterStore)
            // G.6-G.11 — Feed body (placeholder; dispatch fills)
            feedBodyPlaceholder
        }
        .padding(LeafSpace.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - G.3 Toolbar

    @ViewBuilder
    private func toolbar(active: Workspace, memberCount: Int) -> some View {
        HStack(spacing: LeafSpace.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(active.name)
                    .font(LeafType.title.medium)
                    .foregroundStyle(LeafColor.text.primary)
                    .lineLimit(1)
                Text("\(memberCount) member\(memberCount == 1 ? "" : "s")")
                    .font(LeafType.caption)
                    .foregroundStyle(LeafColor.text.tertiary)
            }
            Spacer(minLength: 0)
            // G.3 — [+ Send] button. ⌘N keyboard shortcut.
            // G.6 dispatch wires to a recipient-picker flow for a "broadcast
            // to whole team" send path. For now: no-op (recipient required).
            LeafButton("+ Send", variant: .primary, size: .md) {
                // G.6 will complete this action with a recipient-picker.
            }
            .keyboardShortcut("n", modifiers: .command)
        }
    }

    // MARK: - G.4 Members pill-row

    @ViewBuilder
    private func membersPillRow(members: [TeamMember]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: LeafSpace.sm) {
                ForEach(members, id: \.id) { member in
                    memberPill(member)
                }
            }
        }
    }

    @ViewBuilder
    private func memberPill(_ member: TeamMember) -> some View {
        Button {
            sendSheetRecipient = SendRecipient(id: member.id, member: member)
        } label: {
            HStack(spacing: LeafSpace.xs) {
                LeafAvatar(initials: initials(for: member.displayName), size: .sm)
                Text(member.displayName)
                    .font(LeafType.caption)
                    .foregroundStyle(LeafColor.text.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, LeafSpace.sm)
            .padding(.vertical, LeafSpace.xs)
            .background(LeafColor.surface.raised)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Feed body placeholder (G.6-G.11 dispatch)

    @ViewBuilder
    private var feedBodyPlaceholder: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Text("Team feed — coming in G.6")
                .font(LeafType.caption)
                .foregroundStyle(LeafColor.text.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty state placeholder (G.10 dispatch fills with full copy)

    @ViewBuilder
    private var emptyStatePlaceholder: some View {
        LeafEmptyState(
            icon: LeafIcons.nav.team,
            title: "No team yet",
            description: "Create a workspace or accept an invite to see your team's feed.",
            ctaTitle: nil,
            onCTA: nil
        )
    }

    // MARK: - Error state

    @ViewBuilder
    private func errorContent(message: String) -> some View {
        LeafBanner(
            tone: .danger,
            title: "Couldn't load team",
            description: message,
            ctaTitle: "Try again",
            onCTA: { workspaceReader.refresh() }
        )
        .padding(LeafSpace.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Helpers

    private func initials(for name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
            .uppercased()
        return parts.isEmpty ? "?" : parts
    }

    /// Best-effort self pubkey for TeamFeedReader selfPubkeyHex parameter.
    /// Falls back to "" — TeamFeedReader treats "" as "no self-exclusion" (graceful).
    private func selfPubkeyHex() -> String {
        guard let key = try? IdentityService.ensureLocalIdentity(at: TeamKeystore.defaultRoot()) else {
            return ""
        }
        return key.publicKey.rawRepresentation
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

// MARK: - FeedFilterChipsBindable

/// @Observable bridge: provides a manual `Binding<Set<FeedFilter>>` to `LeafFilterChips`
/// that routes write-backs through `FeedFilterStore.applySelection(_:)` to ensure
/// persistence is triggered. `@Bindable` alone generates a setter that writes directly
/// to `store.selected`, bypassing persistence — this wrapper closes that gap.
@MainActor
private struct FeedFilterChipsBindable: View {
    var store: FeedFilterStore

    var body: some View {
        LeafFilterChips(
            visibleFilters: [.all, .directMessages, .openTasks, .decisions, .blockers],
            popoverFilters: ShareSource.allCases.map { .shareSource($0) },
            selected: Binding(
                get: { store.selected },
                set: { store.applySelection($0) }
            )
        )
    }
}
