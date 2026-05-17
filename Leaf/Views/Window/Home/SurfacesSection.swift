//
//  SurfacesSection.swift
//  Track 7 P1 — partitions HomeSurface.allCases into enabled (full
//  SurfaceCards top) and disabled (compact SurfaceRows below). Claude Code
//  uses a real view-model + payload; the remaining 5 surfaces use a "Captured ·
//  Coming soon" placeholder card once their enable-state store says ON
//  (Payload mapper lands in P2-collapsed).
//

import SwiftUI
import LeafCore

struct SurfacesSection: View {
    let snapshot: InsightsSnapshot?

    @Environment(PermissionsService.self) private var permissions
    @Environment(RouteCoordinator.self) private var coordinator
    @Environment(WindowState.self) private var windowState
    // Track-7 — Browsers + Calendar enable-state sources. P2-collapsed will
    // replace the placeholder cards with real Payload mappers.
    @Environment(BrowserAllowListStore.self) private var browserAllowList
    @Environment(GoogleCalendarOAuthService.self) private var calendarOAuth

    /// Canonical bundle identifiers — same strings used by
    /// LocalAppsSettingsSection so the Home enable-state stays in lockstep
    /// with the Settings toggle.
    private static let xcodeBundleID = "com.apple.dt.Xcode"
    private static let zoomBundleID  = "us.zoom.xos"

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("SURFACES")
                .leafSectionLabel()
                .foregroundStyle(LeafColor.text.tertiary)

            let parts = partitioned()

            VStack(spacing: LeafSpace.md) {
                ForEach(parts.enabled, id: \.self) { surface in
                    enabledCard(for: surface)
                }
                ForEach(parts.disabled, id: \.self) { surface in
                    disabledRow(for: surface)
                }
            }
        }
        .onAppear {
            // Browsers needs allow-list emptiness; Calendar OAuth state is
            // populated lazily from `integrations` on first read. Both calls
            // are idempotent and cheap.
            browserAllowList.load()
            calendarOAuth.reload()
        }
    }

    // MARK: - Partition

    private struct Partition {
        var enabled: [HomeSurface]
        var disabled: [HomeSurface]
    }

    private func partitioned() -> Partition {
        var enabled: [HomeSurface] = []
        var disabled: [HomeSurface] = []
        for surface in SurfaceCatalog.all {
            if isEnabled(surface) {
                enabled.append(surface)
            } else {
                disabled.append(surface)
            }
        }
        return Partition(enabled: enabled, disabled: disabled)
    }

    private func isEnabled(_ surface: HomeSurface) -> Bool {
        switch surface {
        case .claudeCode:
            return permissions.aiToolsStore.isEnabled("claude_code")
        case .xcode:
            return permissions.localAppsStore.isEnabled(Self.xcodeBundleID)
        case .ides:
            // Either IDE-storage watcher (VSCode-family workspaceStorage OR
            // JetBrains recentProjects) opted in promotes the surface.
            return permissions.localAppsStore.vscodeStorageEnabled
                || permissions.localAppsStore.jetbrainsStorageEnabled
        case .browsers:
            // Any browser engagement opted in: per-domain allow-list non-empty
            // (covers Safari + Chrome + Arc navigation depth) OR a bookmark
            // watcher (Chrome / Safari) opted in.
            return !browserAllowList.entries.isEmpty
                || permissions.localAppsStore.browserBookmarksChromeEnabled
                || permissions.localAppsStore.browserBookmarksSafariEnabled
        case .zoom:
            return permissions.localAppsStore.isEnabled(Self.zoomBundleID)
        case .calendar:
            if case .connected = calendarOAuth.state { return true }
            return false
        }
    }

    // MARK: - Enabled card

    @ViewBuilder
    private func enabledCard(for surface: HomeSurface) -> some View {
        switch surface {
        case .claudeCode:
            ClaudeCodeCardWrapper(
                snapshot: snapshot,
                toolsStore: permissions.aiToolsStore,
                onTap: { coordinator.pushHome(.claudeCode) }
            )
        case .xcode, .ides, .browsers, .zoom, .calendar:
            // Track-7 promoted-but-no-payload placeholder. The surface is
            // capturing (its store / OAuth says ON) but the per-surface
            // Payload mapper lands in P2-collapsed. Tap routes into the
            // detail screen which already renders a "coming soon" empty
            // state today; the card itself signals the same.
            SurfaceCard(
                surface: surface,
                headline: "Captured",
                subStats: ["Detail coming soon"],
                spark: { Color.clear },
                onTap: { coordinator.pushHome(surface) }
            )
        }
    }

    // MARK: - Disabled row

    @ViewBuilder
    private func disabledRow(for surface: HomeSurface) -> some View {
        switch surface {
        case .claudeCode:
            SurfaceRow(surface: surface, action: .enable) {
                coordinator.route(.settings(section: .aiTools, sub: .claudeCode), windowState: windowState)
            }
        case .xcode:
            SurfaceRow(surface: surface, action: .enable) {
                coordinator.route(.settings(section: .localApps, sub: .xcode), windowState: windowState)
            }
        case .ides:
            SurfaceRow(surface: surface, action: .enable) {
                coordinator.route(.settings(section: .systemObservers, sub: .ides), windowState: windowState)
            }
        case .browsers:
            SurfaceRow(surface: surface, action: .enable) {
                coordinator.route(.settings(section: .systemObservers, sub: .browsers), windowState: windowState)
            }
        case .zoom:
            SurfaceRow(surface: surface, action: .enable) {
                coordinator.route(.settings(section: .localApps, sub: .zoom), windowState: windowState)
            }
        case .calendar:
            SurfaceRow(surface: surface, action: .connect) {
                coordinator.route(.connections, windowState: windowState)
            }
        }
    }
}

// MARK: - Claude Code card wrapper

private struct ClaudeCodeCardWrapper: View {
    let snapshot: InsightsSnapshot?
    let toolsStore: AIToolsStore
    let onTap: () -> Void

    var body: some View {
        switch ClaudeCodeSurfaceCardViewModel.state(toolsStore: toolsStore, snapshot: snapshot) {
        case .disabled:
            // Should not be reached — SurfacesSection only routes here when
            // isEnabled is true. Fall back gracefully.
            EmptyView()
        case .enabledLoading:
            SurfaceCard(
                surface: .claudeCode,
                headline: "Loading…",
                subStats: [],
                spark: { Color.clear },
                onTap: onTap
            )
        case .enabledZeroToday, .enabledEmpty:
            SurfaceCard(
                surface: .claudeCode,
                headline: "Open for details",
                subStats: ["Daily activity in the detail screen"],
                spark: { Color.clear },
                onTap: onTap
            )
        case .enabledPopulated(let payload):
            SurfaceCard(
                surface: .claudeCode,
                headline: ClaudeCodeHeadlineFormatter.tokens(payload.tokensTotal),
                subStats: subStats(for: payload),
                spark: { LeafSparkline(values: payload.dailyTokens) },
                onTap: onTap
            )
        case .error(let message):
            SurfaceCard(
                surface: .claudeCode,
                headline: "Couldn't load",
                subStats: [message],
                spark: { Color.clear },
                onTap: onTap
            )
        }
    }

    private func subStats(for payload: ClaudeCodeCardPayload) -> [String] {
        var out: [String] = []
        if payload.toolCallsCount > 0 {
            out.append("\(payload.toolCallsCount) tool calls")
        }
        if payload.sessionCount > 0 {
            out.append("\(payload.sessionCount) session\(payload.sessionCount == 1 ? "" : "s")")
        }
        return out
    }
}
