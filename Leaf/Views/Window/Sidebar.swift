//
//  Sidebar.swift
//  Track 2 / D2 — three-group sidebar (LEAF / COLLABORATION / ACCOUNT) на
//  LeafNavRow (D1 organism O3). Grouping живёт исключительно тут — каждая
//  группа хардкодит свои WindowSection cases. Badge slot и shortcut slot
//  пустые (D2 baseline; D3+ может wire'нуть для Activity unread / etc).
//
//  Render pattern matches LeafNavRowPreview (TokensPreview) — flat VStack,
//  not List. macOS' List(selection:) с .listStyle(.sidebar) накладывает
//  native sidebar selection chrome (saturated accent fill) поверх
//  LeafNavRow's own accent.subtle background — design-system intent
//  единственно one source of truth for selection visuals: LeafNavRow.
//
//  Track 3 D2 — Connections nav row gains a small red attention dot when
//  GitHubScopesReader signals `.connectedScopeOutdated`. Track 3 D3 extends
//  the OR-condition to also fire when SlackScopesReader is outdated; Linear
//  scope reader будет wire'нут в Track 3 D4. Dot rendered как
//  `LeafDot(tone: .danger, size: .sm)` overlay topTrailing на nav row
//  (LeafNavRow API не трогаем — `badge: Int?` это отдельная количественная
//  семантика, attention dot — bool urgency cue, ортогонально).
//
//  Track 5 / S7 G.12 — removed `.organization` from COLLABORATION group;
//  replaced with LeafWorkspaceSwitcher anchored at the sidebar bottom.
//  Layout: VStack { ScrollView (nav groups) + Spacer + switcher section }.
//

import SwiftUI
import LeafCore

struct Sidebar: View {
    @Binding var selection: WindowSection

    @Environment(GitHubScopesReader.self) private var githubScopes
    @Environment(SlackScopesReader.self) private var slackScopes
    @Environment(WorkspaceReader.self) private var workspaceReader
    @Environment(ActiveWorkspaceStore.self) private var activeWorkspaceStore
    @Environment(DirectMessageInboxReader.self) private var inboxReader
    /// T4 — tier gate. Free-tier swaps `LeafWorkspaceSwitcher` for an
    /// «Upgrade to add workspaces» row at the sidebar bottom.
    @Environment(TierGateReader.self) private var tierGate
    @Environment(\.submitToWaitlist) private var submitToWaitlist

    @State private var leavePresented = false
    @State private var leaveTargetWorkspaceID: String?
    @State private var createWorkspacePresented = false
    /// T4 — per-callsite UpgradeModal flag for the Free-tier switcher row.
    @State private var showUpgrade = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: LeafSpace.lg) {
                    group(title: "LEAF", items: [.home, .activity])
                    group(title: "COLLABORATION", items: [.team, .connections])
                    group(title: "ACCOUNT", items: [.settings, .profile])
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, LeafSpace.md)
            }
            Spacer(minLength: 0)
            workspaceSwitcherSection
        }
        .sheet(isPresented: $leavePresented) {
            if let wid = leaveTargetWorkspaceID,
               let workspace = workspacesByID[wid] {
                LeaveWorkspaceConfirmationModal(
                    workspaceName: workspace.name,
                    onConfirm: {
                        // S7 Stage 6 fix C-C2 — call leaveWorkspace(workspaceID:)
                        // directly. The earlier `setActive(wid) + leaveActiveWorkspace()`
                        // shape relied on WorkspaceReader.state.active being read
                        // *after* setActive, but setActive does not refresh the
                        // Reader's state — leaveActiveWorkspace() would read the
                        // previous active workspace and mark the *wrong* row left.
                        workspaceReader.leaveWorkspace(workspaceID: wid)
                        leavePresented = false
                        leaveTargetWorkspaceID = nil
                    },
                    onCancel: {
                        leavePresented = false
                        leaveTargetWorkspaceID = nil
                    }
                )
            }
        }
        .sheet(isPresented: $createWorkspacePresented) {
            WorkspaceCreateSheet(
                onCreated: {
                    workspaceReader.refresh()
                    createWorkspacePresented = false
                },
                onCancel: { createWorkspacePresented = false }
            )
        }
        .sheet(isPresented: $showUpgrade) {
            UpgradeModal(
                reason: .createWorkspace,
                onDismiss: { showUpgrade = false },
                onSubmitEmail: { email in await submitToWaitlist(email) }
            )
        }
    }

    // MARK: - Workspace Switcher

    @ViewBuilder
    private var workspaceSwitcherSection: some View {
        // T4 — Free-tier: replace LeafWorkspaceSwitcher with a single
        // «Upgrade to add workspaces» row. Free user has no workspaces, so
        // there's nothing to switch *to* anyway — the row serves both as
        // empty state AND the upgrade CTA in one strike.
        if !tierGate.canCreateWorkspace {
            freeStateSwitcherRow
        } else {
            teamStateSwitcher
        }
    }

    @ViewBuilder
    private var teamStateSwitcher: some View {
        let workspaces: [Workspace] = {
            if case .loaded(let ws, _, _) = workspaceReader.state { return ws }
            return []
        }()
        let activeWid = activeWorkspaceStore.activeWorkspaceID
        let sorted = workspaces
            .filter { $0.leftAt == nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        LeafWorkspaceSwitcher(
            workspaces: sorted,
            activeWorkspaceID: activeWid,
            unreadCounts: inboxReader.unreadCountByWorkspace,
            // S7 Stage 6 fix C-C3 — route through switchActive(to:) so the
            // Reader's state.active is refreshed alongside the store; otherwise
            // TeamView renders the previous workspace's name and members
            // because state.active is only re-resolved on refresh().
            onSelect: { wid in workspaceReader.switchActive(to: wid) },
            onAddNew: { createWorkspacePresented = true },
            onLeave: { wid in
                leaveTargetWorkspaceID = wid
                leavePresented = true
            },
            onMarkAllRead: { _ in
                // TODO: Phase v1.1 — bulk mark-read
                // Wire: inboxReader.markAllReadForWorkspace(wid)
            }
        )
    }

    /// T4 — Free-tier switcher row. Visually rhymes with LeafWorkspaceSwitcher
    /// internals (LeafColor.surface.inset background, similar padding/height)
    /// so the sidebar bottom feels continuous between tiers.
    @ViewBuilder
    private var freeStateSwitcherRow: some View {
        Button {
            showUpgrade = true
        } label: {
            HStack(spacing: LeafSpace.sm) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(LeafColor.status.warning)
                Text("Upgrade to add workspaces")
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.primary)
                Spacer(minLength: 0)
            }
            .padding(LeafSpace.md)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(LeafColor.surface.inset)
    }

    // MARK: - Helpers

    /// True when any wired provider scope-status reader signals outdated.
    /// D2 wires only GitHub; D3 adds Slack via OR-condition; Track 3 D4
    /// generalizes per-provider scope status.
    private var connectionsNeedsAttention: Bool {
        if case .connectedScopeOutdated = githubScopes.state { return true }
        if case .connectedScopeOutdated = slackScopes.state { return true }
        return false
    }

    private var workspacesByID: [String: Workspace] {
        let workspaces: [Workspace] = {
            if case .loaded(let ws, _, _) = workspaceReader.state { return ws }
            return []
        }()
        return Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
    }

    @ViewBuilder
    private func group(title: String, items: [WindowSection]) -> some View {
        VStack(alignment: .leading, spacing: LeafSpace.xs) {
            Text(title)
                .leafSectionLabel()
                .foregroundStyle(LeafColor.text.tertiary)
                .padding(.horizontal, LeafSpace.md)

            VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                ForEach(items) { item in
                    LeafNavRow(
                        icon: item.iconIsSystem ? .system(item.icon) : .asset(item.icon),
                        title: item.title,
                        isSelected: Binding(
                            get: { selection == item },
                            set: { if $0 { selection = item } }
                        ),
                        onTap: { selection = item }
                    )
                    .overlay(alignment: .topTrailing) {
                        if item == .connections, connectionsNeedsAttention {
                            LeafDot(tone: .danger, size: .sm)
                                .padding(LeafSpace.sm)
                                .accessibilityLabel("Attention required")
                        }
                    }
                }
            }
        }
    }
}
