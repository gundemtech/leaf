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
        case .xcode:
            XcodeCardWrapper(
                snapshot: snapshot,
                localAppsStore: permissions.localAppsStore,
                onTap: { coordinator.pushHome(.xcode) }
            )
        case .ides:
            IDEsCardWrapper(
                snapshot: snapshot,
                localAppsStore: permissions.localAppsStore,
                onTap: { coordinator.pushHome(.ides) }
            )
        case .browsers:
            BrowsersCardWrapper(
                snapshot: snapshot,
                localAppsStore: permissions.localAppsStore,
                browserAllowList: browserAllowList,
                onTap: { coordinator.pushHome(.browsers) }
            )
        case .zoom:
            ZoomCardWrapper(
                snapshot: snapshot,
                localAppsStore: permissions.localAppsStore,
                onTap: { coordinator.pushHome(.zoom) }
            )
        case .calendar:
            GoogleCalendarCardWrapper(
                snapshot: snapshot,
                calendarOAuth: calendarOAuth,
                onTap: { coordinator.pushHome(.calendar) }
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

// MARK: - Surface duration helper

/// Shared formatter for surfaces that surface a total-time headline (Zoom,
/// Google Calendar focus duration). Hours when >= 1h, otherwise minutes.
private func formatHours(_ seconds: TimeInterval) -> String {
    let hours = seconds / 3600.0
    if hours >= 1 { return String(format: "%.1fh", hours) }
    let minutes = Int(seconds / 60.0)
    return "\(minutes)m"
}

// MARK: - Xcode card wrapper

private struct XcodeCardWrapper: View {
    let snapshot: InsightsSnapshot?
    let localAppsStore: LocalAppsStore
    let onTap: () -> Void

    var body: some View {
        switch XcodeSurfaceCardViewModel.state(localAppsStore: localAppsStore, snapshot: snapshot) {
        case .disabled:
            EmptyView()
        case .enabledLoading:
            SurfaceCard(
                surface: .xcode,
                headline: "Loading…",
                subStats: [],
                spark: { Color.clear },
                onTap: onTap
            )
        case .enabledZeroToday, .enabledEmpty:
            SurfaceCard(
                surface: .xcode,
                headline: "Open for details",
                subStats: ["Daily activity in the detail screen"],
                spark: { Color.clear },
                onTap: onTap
            )
        case .enabledPopulated(let payload):
            SurfaceCard(
                surface: .xcode,
                headline: "\(payload.buildCount) build\(payload.buildCount == 1 ? "" : "s") · \(payload.testRunCount) test\(payload.testRunCount == 1 ? "" : "s")",
                subStats: subStats(for: payload),
                spark: { LeafSparkline(values: payload.dailyBuilds) },
                onTap: onTap
            )
        case .error(let message):
            SurfaceCard(
                surface: .xcode,
                headline: "Couldn't load",
                subStats: [message],
                spark: { Color.clear },
                onTap: onTap
            )
        }
    }

    private func subStats(for payload: XcodeCardPayload) -> [String] {
        var out: [String] = []
        if payload.buildSuccessCount > 0 {
            out.append("\(payload.buildSuccessCount) passed")
        }
        if payload.buildFailureCount > 0 {
            out.append("\(payload.buildFailureCount) failed")
        }
        if payload.schemesTouchedCount > 0 {
            out.append("\(payload.schemesTouchedCount) scheme\(payload.schemesTouchedCount == 1 ? "" : "s") touched")
        }
        return out
    }
}

// MARK: - IDEs card wrapper

private struct IDEsCardWrapper: View {
    let snapshot: InsightsSnapshot?
    let localAppsStore: LocalAppsStore
    let onTap: () -> Void

    var body: some View {
        switch IDEsSurfaceCardViewModel.state(localAppsStore: localAppsStore, snapshot: snapshot) {
        case .disabled:
            EmptyView()
        case .enabledLoading:
            SurfaceCard(
                surface: .ides,
                headline: "Loading…",
                subStats: [],
                spark: { Color.clear },
                onTap: onTap
            )
        case .enabledZeroToday, .enabledEmpty:
            SurfaceCard(
                surface: .ides,
                headline: "Open for details",
                subStats: ["Daily activity in the detail screen"],
                spark: { Color.clear },
                onTap: onTap
            )
        case .enabledPopulated(let payload):
            SurfaceCard(
                surface: .ides,
                headline: "\(payload.fileEventCount) file\(payload.fileEventCount == 1 ? "" : "s") in \(payload.workspaceCount) workspace\(payload.workspaceCount == 1 ? "" : "s")",
                subStats: subStats(for: payload),
                spark: { LeafSparkline(values: payload.dailyEvents) },
                onTap: onTap
            )
        case .error(let message):
            SurfaceCard(
                surface: .ides,
                headline: "Couldn't load",
                subStats: [message],
                spark: { Color.clear },
                onTap: onTap
            )
        }
    }

    private func subStats(for payload: IDEsCardPayload) -> [String] {
        var out: [String] = []
        if payload.vscodeFamilyEventCount > 0 {
            out.append("VSCode-family: \(payload.vscodeFamilyEventCount)")
        }
        if payload.jetbrainsEventCount > 0 {
            out.append("JetBrains: \(payload.jetbrainsEventCount)")
        }
        if payload.fallbackTitleCount > 0 {
            out.append("\(payload.fallbackTitleCount) fallback titles")
        }
        return out
    }
}

// MARK: - Browsers card wrapper

private struct BrowsersCardWrapper: View {
    let snapshot: InsightsSnapshot?
    let localAppsStore: LocalAppsStore
    let browserAllowList: BrowserAllowListStore
    let onTap: () -> Void

    var body: some View {
        switch BrowsersSurfaceCardViewModel.state(
            localAppsStore: localAppsStore,
            browserAllowList: browserAllowList,
            snapshot: snapshot
        ) {
        case .disabled:
            EmptyView()
        case .enabledLoading:
            SurfaceCard(
                surface: .browsers,
                headline: "Loading…",
                subStats: [],
                spark: { Color.clear },
                onTap: onTap
            )
        case .enabledZeroToday, .enabledEmpty:
            SurfaceCard(
                surface: .browsers,
                headline: "Open for details",
                subStats: ["Daily activity in the detail screen"],
                spark: { Color.clear },
                onTap: onTap
            )
        case .enabledPopulated(let payload):
            SurfaceCard(
                surface: .browsers,
                headline: "\(payload.pageCount) page\(payload.pageCount == 1 ? "" : "s") on \(payload.domainCount) domain\(payload.domainCount == 1 ? "" : "s")",
                subStats: subStats(for: payload),
                spark: { LeafSparkline(values: payload.dailyNavigations) },
                onTap: onTap
            )
        case .error(let message):
            SurfaceCard(
                surface: .browsers,
                headline: "Couldn't load",
                subStats: [message],
                spark: { Color.clear },
                onTap: onTap
            )
        }
    }

    private func subStats(for payload: BrowsersCardPayload) -> [String] {
        var out: [String] = []
        if payload.safariCount > 0 {
            out.append("Safari: \(payload.safariCount)")
        }
        if payload.chromeCount > 0 {
            out.append("Chrome: \(payload.chromeCount)")
        }
        if payload.arcCount > 0 {
            out.append("Arc: \(payload.arcCount)")
        }
        if payload.bookmarksAddedCount > 0 {
            out.append("\(payload.bookmarksAddedCount) bookmarks added")
        }
        return out
    }
}

// MARK: - Zoom card wrapper

private struct ZoomCardWrapper: View {
    let snapshot: InsightsSnapshot?
    let localAppsStore: LocalAppsStore
    let onTap: () -> Void

    var body: some View {
        switch ZoomSurfaceCardViewModel.state(localAppsStore: localAppsStore, snapshot: snapshot) {
        case .disabled:
            EmptyView()
        case .enabledLoading:
            SurfaceCard(
                surface: .zoom,
                headline: "Loading…",
                subStats: [],
                spark: { Color.clear },
                onTap: onTap
            )
        case .enabledZeroToday, .enabledEmpty:
            SurfaceCard(
                surface: .zoom,
                headline: "Open for details",
                subStats: ["Daily activity in the detail screen"],
                spark: { Color.clear },
                onTap: onTap
            )
        case .enabledPopulated(let payload):
            SurfaceCard(
                surface: .zoom,
                headline: "\(formatHours(payload.totalDurationSeconds)) meeting time",
                subStats: subStats(for: payload),
                spark: { LeafSparkline(values: payload.dailyMinutes) },
                onTap: onTap
            )
        case .error(let message):
            SurfaceCard(
                surface: .zoom,
                headline: "Couldn't load",
                subStats: [message],
                spark: { Color.clear },
                onTap: onTap
            )
        }
    }

    private func subStats(for payload: ZoomCardPayload) -> [String] {
        var out: [String] = []
        out.append("\(payload.meetingCount) meeting\(payload.meetingCount == 1 ? "" : "s")")
        if payload.calendarLinkedCount > 0 {
            out.append("\(payload.calendarLinkedCount) calendar-linked")
        }
        if payload.adHocCount > 0 {
            out.append("\(payload.adHocCount) ad-hoc")
        }
        return out
    }
}

// MARK: - Google Calendar card wrapper

/// Calendar carve-out per spec §3.5: zero-today renders `"Captured · Waiting
/// for events"` (not the generic "Open for details"), because the surface is
/// gated on GCP acceptance and we want to differentiate between
/// "captured-but-quiet today" and "captured-but-not-yet-aggregated".
private struct GoogleCalendarCardWrapper: View {
    let snapshot: InsightsSnapshot?
    let calendarOAuth: GoogleCalendarOAuthService
    let onTap: () -> Void

    var body: some View {
        switch GoogleCalendarSurfaceCardViewModel.state(calendarOAuth: calendarOAuth, snapshot: snapshot) {
        case .disabled:
            EmptyView()
        case .enabledLoading:
            SurfaceCard(
                surface: .calendar,
                headline: "Loading…",
                subStats: [],
                spark: { Color.clear },
                onTap: onTap
            )
        case .enabledZeroToday, .enabledEmpty:
            SurfaceCard(
                surface: .calendar,
                headline: "Captured · Waiting for events",
                subStats: ["Detail aggregates after GCP gate clears"],
                spark: { Color.clear },
                onTap: onTap
            )
        case .enabledPopulated(let payload):
            SurfaceCard(
                surface: .calendar,
                headline: "\(payload.focusBlockCount) focus block\(payload.focusBlockCount == 1 ? "" : "s") · \(formatHours(payload.focusDurationSeconds))",
                subStats: subStats(for: payload),
                spark: { LeafSparkline(values: payload.dailyFocusMinutes) },
                onTap: onTap
            )
        case .error(let message):
            SurfaceCard(
                surface: .calendar,
                headline: "Couldn't load",
                subStats: [message],
                spark: { Color.clear },
                onTap: onTap
            )
        }
    }

    private func subStats(for payload: GoogleCalendarCardPayload) -> [String] {
        var out: [String] = []
        if payload.oooBlockCount > 0 {
            out.append("\(payload.oooBlockCount) OOO blocks")
        }
        if payload.workingLocationCount > 0 {
            out.append("\(payload.workingLocationCount) working location entries")
        }
        return out
    }
}
