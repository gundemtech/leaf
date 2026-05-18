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

    @State private var leavePresented = false
    @State private var leaveTargetWorkspaceID: String?
    @State private var createWorkspacePresented = false

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
                        if activeWorkspaceStore.activeWorkspaceID == wid {
                            await workspaceReader.leaveActiveWorkspace()
                        } else {
                            activeWorkspaceStore.setActive(wid)
                            await workspaceReader.leaveActiveWorkspace()
                        }
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
    }

    // MARK: - Workspace Switcher

    @ViewBuilder
    private var workspaceSwitcherSection: some View {
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
            onSelect: { wid in activeWorkspaceStore.setActive(wid) },
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
