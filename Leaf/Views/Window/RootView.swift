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
    // Track 5 / S7 Stage 6 fix C-C1 — 30s polling tick host. OrganizationView
    // (which previously hosted the polling loop) was deleted in commit 1a3fbcc;
    // these readers' .tick() methods had no caller until rewired here. The loop
    // is the latency-tolerant fallback delivery path when Realtime is down /
    // suspended / decryption-stubbed (Phase H carry-over).
    @Environment(DirectMessageInboxReader.self) private var directMessageInboxReader
    @Environment(TeamEventBroadcastReader.self) private var teamEventBroadcastReader
    @Environment(TeamEventMirrorReader.self) private var teamEventMirrorReader
    /// Track 5 / S8 T6 — daily-tick retry queue for APNs `dm.markDone`.
    /// Optional because Database open at LeafApp.init can fail (graceful);
    /// nil → skip the tick. Driven from the polling loop below alongside
    /// the existing TeamEventMirrorRetentionPruner pruner tick.
    @Environment(\.pendingMarkDoneRetryService) private var pendingMarkDoneRetryService
    /// Track 5 / S8 / T8 — daily-tick auto-pruner for workspaces past 30d
    /// since left_at_ms OR deleted_at_ms. Optional for the same DB-open
    /// graceful-degrade reason as `pendingMarkDoneRetryService`. The
    /// per-30s outer loop just gives the actor a chance to check; the
    /// pruner itself is idempotent (already-wiped rows no longer match the
    /// SELECT predicate).
    @Environment(\.workspaceCascadeDeleter) private var workspaceCascadeDeleter
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
        //
        // `.task(id: scenePhase)` instead of `.onChange + Task { }` so SwiftUI
        // cancels the prior dispatch when scenePhase flips fast (lid-flip /
        // rapid sleep-wake). The earlier `.onChange` shape spawned an
        // unstructured Task per transition; concurrent resume/suspend pairs
        // could race past the `subscribe` idempotency guard and stack
        // phx_join frames on the WS.
        .task(id: scenePhase) {
            if scenePhase == .active {
                await realtimeService.resume()
            } else {
                await realtimeService.suspend()
            }
        }
        // Track 5 / S7 Stage 6 fix C-C1 — 30s polling tick scheduler for
        // broadcast / mirror / DM inbox. Replaces OrganizationView's lifecycle
        // host (deleted in commit 1a3fbcc). Loop terminates when active
        // workspace changes (Task re-issued on .task(id:) match) or window
        // closes (Task cancellation). Cancellation-safe via Task.isCancelled
        // check between awaits + Task.sleep cancellation honours.
        //
        // Why .task(id:) and not .onChange + manual Task: SwiftUI cancels
        // the prior Task automatically on id change, which gives us a clean
        // single-loop-per-workspace invariant.
        .task(id: activeWorkspaceStore.activeWorkspaceID) {
            guard let wid = activeWorkspaceStore.activeWorkspaceID else { return }
            while !Task.isCancelled {
                await teamEventBroadcastReader.tick(workspaceID: wid)
                if Task.isCancelled { break }
                await teamEventMirrorReader.tick(workspaceID: wid)
                if Task.isCancelled { break }
                await directMessageInboxReader.tick()
                if Task.isCancelled { break }
                // Track 5 / S5 — 24h-cooldown retention prune (mirror cleanup).
                await teamEventMirrorReader.pruneIfDueDaily()
                if Task.isCancelled { break }
                // Track 5 / S8 T6 — 24h-cooldown APNs dm.markDone retry queue.
                // Service-internal cooldown gate means the actual server-PATCH
                // loop fires at most once per 24h; the per-30s outer loop just
                // gives the actor a chance to check.
                if let retry = pendingMarkDoneRetryService {
                    try? await retry.tickIfDueDaily()
                }
                if Task.isCancelled { break }
                // Track 5 / S8 / T8 — auto-prune workspaces past the 30-day
                // retention window (left_at_ms OR deleted_at_ms). Idempotent;
                // already-wiped rows no longer match the SELECT predicate.
                // S8 review B-Imp-3 — `tickIfDueDaily` cooldown gates the
                // SELECT to once per 24h so the per-30s polling loop doesn't
                // hammer the workspaces table when no workspace is anywhere
                // near the 30d boundary.
                // If any wipes happened, refresh WorkspaceReader so a left
                // workspace that just got pruned disappears from any UI
                // surface that lists left/deleted workspaces.
                if let deleter = workspaceCascadeDeleter {
                    let wiped = (try? await deleter.tickIfDueDaily()) ?? []
                    if !wiped.isEmpty {
                        workspaceReader.refresh()
                    }
                }
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 30_000_000_000)
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
        case .analytics:    AnalyticsView()
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
