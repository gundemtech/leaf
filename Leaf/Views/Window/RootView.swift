//
//  RootView.swift
//  Track 2 / D2 — main-window root. Two top-level branches:
//    1. RemovedFromTeamBanner full-screen takeover (Phase 5.3.E) when
//       WorkspaceReader.state == .removedFromActiveWorkspace. Tombstone is
//       intentionally OUTSIDE LeafWindowLayout — it's not a section in the
//       nav shell, it's a hard mode change.
//    2. Otherwise: LeafWindowLayout (D1 template T1) — Sidebar + detail
//       slot resolved by WindowState.section. Toolbar carries
//       LeafStatusPill (D1 organism O5) reflecting derived state from
//       InsightsReader.state.
//
//  Refresh discipline: reader.refresh() + workspaceReader.refresh() on appear.
//  .onOpenURL / .scenePhase invite-handling and OpenSettingsCommand stay
//  in LeafApp.swift (Window scene level) — RootView does not duplicate.
//
//  Track 5 S2 Task 10 — migrated OrgReader → WorkspaceReader; banner reads
//  workspace name from .removedFromActiveWorkspace(workspaceName:).
//

import SwiftUI
import LeafCore

struct RootView: View {
    @Environment(WindowState.self) private var windowState
    @Environment(InsightsReader.self) private var reader
    @Environment(WorkspaceReader.self) private var workspaceReader
    // Track 5 / S7 H.4 + H.5 — Realtime subscribe/unsubscribe lifecycle driven
    // by active workspace + scenePhase. The service is @MainActor @Observable
    // so we can pass it through the environment from LeafApp.init.
    @Environment(LeafRealtimeService.self) private var realtimeService
    @Environment(ActiveWorkspaceStore.self) private var activeWorkspaceStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if case .removedFromActiveWorkspace(let workspaceName) = workspaceReader.state {
                RemovedFromTeamBanner(orgName: workspaceName)
            } else {
                shell
            }
        }
        .onAppear {
            reader.refresh()
            workspaceReader.refresh()
        }
        // Track 5 / S7 H.4 — Subscribe Realtime to the active workspace channel.
        // Triggered on active workspace change AND on initial appearance.
        // Idempotent: same workspaceID → no-op (LeafRealtimeService.subscribe).
        // nil workspaceID → unsubscribe (defensive — workspace not yet resolved
        // or user just left the only workspace).
        .task(id: activeWorkspaceStore.activeWorkspaceID) {
            if let wid = activeWorkspaceStore.activeWorkspaceID {
                await realtimeService.subscribe(workspaceID: wid)
            } else {
                await realtimeService.unsubscribe()
            }
        }
        // Track 5 / S7 H.5 — Suspend/resume Realtime on scenePhase boundary to
        // save battery in background. resume() recovers via persisted active
        // workspace; suspend() closes WS + cancels reconnect timers.
        .onChange(of: scenePhase) { _, phase in
            Task {
                if phase == .active {
                    await realtimeService.resume()
                } else {
                    await realtimeService.suspend()
                }
            }
        }
    }

    @ViewBuilder
    private var shell: some View {
        @Bindable var binding = windowState

        LeafWindowLayout {
            Sidebar(selection: $binding.section)
        } detail: {
            detail(for: windowState.section)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        LeafStatusPill(state: derivedStatusPillState())
                    }
                }
        }
        .frame(
            minWidth:  LeafWindowLayoutTokens.windowMinWidth,
            minHeight: LeafWindowLayoutTokens.windowMinHeight
        )
    }

    @ViewBuilder
    private func detail(for section: WindowSection) -> some View {
        switch section {
        case .home:         HomeView()
        case .activity:     ActivityView()
        case .team:         TeamView()
        case .connections:  ConnectionsView()
        case .settings:     WindowSettingsView()
        case .profile:      ProfileView()
        }
    }

    /// Derive status pill state from InsightsReader.
    /// `.sharing` / `.invisible` wired in Phase 5.4 (presence_outgoing).
    /// In D2 only `.active` ↔ `.idle` flip on session-age boundary.
    /// Boundary value lives in LeafStatusPillTokens.activeThresholdSeconds
    /// (single source of truth — Phase 5.4 will reuse for presence snapshot).
    private func derivedStatusPillState() -> LeafStatusPillState {
        guard case .loaded(let snapshot, _) = reader.state,
              let mostRecent = snapshot.recentSessions.first,
              Date().timeIntervalSince(mostRecent.end) <= LeafStatusPillTokens.activeThresholdSeconds
        else {
            return .idle
        }
        return .active
    }
}
