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

    /// C-4 (Phase 8.9) — cached locale-aware "EEE d MMM" formatter so the
    /// "TODAY · <date>" label doesn't allocate a `DateFormatter` per body
    /// re-eval. Locale captured at first access; relaunch refreshes if the
    /// user changes system locale mid-session (acceptable per spec §3.4).
    private static let sectionDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return f
    }()

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
        "TODAY · \(Self.sectionDateFormatter.string(from: Date()))"
    }

    // MARK: - Metrics row

    /// C-3 (Phase 8.9) — `ViewThatFits` picks the wide horizontal row when
    /// it fits in the available width, otherwise falls through to a 2×2
    /// grid. No `@State`, no GeometryReader, no fixed cutoff — SwiftUI
    /// measures intrinsic content width per branch.
    private var metricsRow: some View {
        ViewThatFits(in: .horizontal) {
            // Wide branch — 4 cells horizontal (current shape).
            HStack(alignment: .top, spacing: LeafSpace.lg) {
                metricCell(value: focusValue, label: "focused")
                metricCell(value: aiRatioValue, label: "AI ratio")
                metricCell(value: "\(metrics.sessionsCount)", label: "sessions")
                metricCell(value: "\(metrics.commitsCount)", label: "commits")
                Spacer(minLength: 0)
            }
            // Narrow branch — 2×2 grid; same metric cells, no expand state.
            VStack(alignment: .leading, spacing: LeafSpace.md) {
                HStack(alignment: .top, spacing: LeafSpace.lg) {
                    metricCell(value: focusValue, label: "focused")
                    metricCell(value: aiRatioValue, label: "AI ratio")
                    Spacer(minLength: 0)
                }
                HStack(alignment: .top, spacing: LeafSpace.lg) {
                    metricCell(value: "\(metrics.sessionsCount)", label: "sessions")
                    metricCell(value: "\(metrics.commitsCount)", label: "commits")
                    Spacer(minLength: 0)
                }
            }
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
        // Phase 8.9 a11y: combine "42m" + "focused" into a single
        // VoiceOver element so the metric reads as "42m focused" rather
        // than two adjacent elements losing unit context.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(label)")
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
        let title = pillLabel(for: pill)
        if let route = SurfacePillRouter.route(forPillID: pill.id) {
            Button {
                push(route)
            } label: {
                LeafPill(title: title)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title) — open details")
            .accessibilityAddTraits(.isButton)
        } else {
            LeafPill(title: title)
        }
    }

    /// Track-9 T6 — kind-switched pill label format. `.captureTime` carries
    /// seconds (rendered as "Xh Ym" / "Nm" / "<1m"); `.actionNoun` carries
    /// discrete count (rendered as "N").
    private func pillLabel(for pill: SurfacePill) -> String {
        let suffix: String
        switch pill.kind {
        case .captureTime:
            suffix = formatDurationCompact(seconds: pill.count)
        case .actionNoun:
            suffix = "\(pill.count)"
        }
        return "\(pill.label) \(suffix)"
    }

    private func formatDurationCompact(seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "<1m"
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
