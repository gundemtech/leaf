//
//  SurfacesSection.swift
//  Track 7 P1 — partitions HomeSurface.allCases into enabled (full
//  SurfaceCards top) and disabled (compact SurfaceRows below). In P1 only
//  Claude Code is wired through a real view-model + payload — the other 5
//  surfaces always render as compact disabled rows (P2-P6 wire them up).
//

import SwiftUI
import LeafCore

struct SurfacesSection: View {
    let snapshot: InsightsSnapshot?

    @Environment(PermissionsService.self) private var permissions
    @Environment(RouteCoordinator.self) private var coordinator
    @Environment(WindowState.self) private var windowState

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
        case .xcode, .ides, .browsers, .zoom, .calendar:
            // P2-P6 will wire each surface to its enable-state source.
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
            // Unreachable in P1 — isEnabled returns false for these.
            // Defensive EmptyView; P2-P6 will replace this with real wrappers.
            EmptyView()
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
