//
//  TodayBlock.swift
//  Track 8 / Phase 8.3 — TODAY anchor block. Renders the glanceable today
//  snapshot (focused / AI ratio / sessions / switches / commits) and a
//  surface pill strip routing to detail screens via SurfacePillRouter.
//  Phase 8.1 substrate produces the metrics via
//  DerivedInsights.todayMetrics(now:); InsightsReader.refresh() invokes it
//  once per refresh and threads the result through InsightsSnapshot.
//

import LeafCore
import SwiftUI

struct TodayBlock: View {
    let metrics: TodayMetrics

    @Environment(RouteCoordinator.self) private var coordinator
    @State private var pillsExpanded = false

    private static let pillVisibleCap = 6

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text(sectionLabel)
                .leafSectionLabel()
                .foregroundStyle(LeafColor.text.tertiary)

            LeafCard(padding: .regular) {
                if metrics == .empty {
                    LeafEmptyState(
                        icon: LeafIcons.brand.leaf,
                        title: "Nothing captured yet today",
                        description: "Activity will appear here as the day goes on."
                    )
                } else {
                    VStack(alignment: .leading, spacing: LeafSpace.md) {
                        metricsRow
                        if !metrics.surfacePills.isEmpty {
                            LeafDivider()
                            pillStrip
                        }
                    }
                }
            }
        }
    }

    private var sectionLabel: String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return "TODAY · \(formatter.string(from: Date()))"
    }

    // MARK: - Metrics row

    private var metricsRow: some View {
        HStack(alignment: .top, spacing: LeafSpace.lg) {
            metricCell(value: focusValue, label: "focused")
            metricCell(value: aiRatioValue, label: "AI ratio")
            metricCell(value: "\(metrics.sessionsCount)", label: "sessions")
            metricCell(value: "\(metrics.commitsCount)", label: "commits")
            Spacer(minLength: 0)
        }
    }

    private func metricCell(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: LeafSpace.xxs) {
            Text(value)
                .font(LeafType.title.medium.monospacedDigit())
                .foregroundStyle(LeafColor.text.primary)
            Text(label)
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.tertiary)
        }
    }

    private var focusValue: String {
        let minutes = metrics.focusedMin
        if minutes == 0 { return "—" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }

    private var aiRatioValue: String {
        let pct = Int((max(0, min(1, metrics.aiRatio)) * 100).rounded())
        return "\(pct)%"
    }

    // MARK: - Pill strip

    private var pillStrip: some View {
        let pills = metrics.surfacePills
        let overflow = pills.count > Self.pillVisibleCap
        let visible: [SurfacePill] =
            (pillsExpanded || !overflow)
            ? pills : Array(pills.prefix(Self.pillVisibleCap))
        let hiddenCount = pills.count - visible.count

        return HStack(spacing: LeafSpace.sm) {
            ForEach(visible) { pill in
                pillButton(pill)
            }
            if overflow && !pillsExpanded {
                overflowChip(remaining: hiddenCount)
            }
        }
        .animation(.default, value: pillsExpanded)
    }

    @ViewBuilder
    private func pillButton(_ pill: SurfacePill) -> some View {
        if let route = SurfacePillRouter.route(forPillID: pill.id) {
            Button {
                push(route)
            } label: {
                LeafPill(title: pill.label)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(pill.label) — open details")
            .accessibilityAddTraits(.isButton)
        } else {
            LeafPill(title: pill.label)
        }
    }

    private func overflowChip(remaining: Int) -> some View {
        Button {
            pillsExpanded = true
        } label: {
            LeafPill(title: "+\(remaining)")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show \(remaining) more surfaces")
        .accessibilityAddTraits(.isButton)
    }

    private func push(_ route: SurfacePillRoute) {
        switch route {
        case .homeSurface(let surface):
            coordinator.pushHome(surface)
        case .layerBProvider(let provider):
            coordinator.pushHomeLayerBProvider(provider)
        }
    }
}
