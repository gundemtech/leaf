//
//  TodayBlock.swift
//  Track 8 / Phase 8.3 — TODAY anchor block. Renders the glanceable today
//  snapshot (focused / AI ratio / sessions / switches / commits). Phase 8.1
//  substrate produces the metrics via DerivedInsights.todayMetrics(now:);
//  InsightsReader.refresh() invokes it once per refresh and threads the
//  result through InsightsSnapshot.
//
//  Track-10 T1 — per-app `pillStrip` removed from the body (substrate
//  `surfacePills` emission preserved as YAGNI-reserve; no current MCP
//  consumer, cleanup carry post-Track-10).
//

import LeafCore
import SwiftUI

struct TodayBlock: View {
    let metrics: TodayMetrics
    let youNowState: YouNowState

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
                .accessibilityAddTraits(.isHeader)

            LeafCard(padding: .regular) {
                if metrics == .empty {
                    LeafEmptyState(
                        icon: LeafIcons.brand.leaf,
                        title: "Nothing captured yet today",
                        description: "Activity will appear here as the day goes on."
                    )
                } else {
                    metricsRow
                }
            }
        }
    }

    private var sectionLabel: String {
        "TODAY · \(Self.sectionDateFormatter.string(from: Date()))"
    }

    // MARK: - Metrics row

    /// Track-9 T6 (C-3 close) — 5-cell wide row + `Grid` 2-col × 3-row narrow.
    /// `ViewThatFits` measures intrinsic content width and picks the first
    /// branch that fits. `switches` cell (substrate-ready since Phase 8.3)
    /// surfaced between `sessions` and `commits`. Narrow grid uses SwiftUI 4+
    /// `Grid` for proper row alignment; bottom-right cell is `Color.clear`
    /// (intentional gap, no 6th metric).
    private var metricsRow: some View {
        ViewThatFits(in: .horizontal) {
            // Wide branch — 5 cells horizontal + badge on its own trailing row.
            VStack(alignment: .leading, spacing: LeafSpace.sm) {
                HStack(alignment: .top, spacing: LeafSpace.lg) {
                    metricCell(value: focusValue, label: "focused")
                    metricCell(value: aiRatioValue, label: "AI ratio")
                    metricCell(value: "\(metrics.sessionsCount)", label: "sessions")
                    metricCell(value: "\(metrics.switchCount)", label: "switches")
                    metricCell(value: "\(metrics.commitsCount)", label: "commits")
                    Spacer(minLength: 0)
                }
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    YouNowStateBadge(state: youNowState)
                }
            }
            // Narrow branch — Grid 2 cols × 3 rows; badge on its own
            // trailing row below the Grid (mirrors the wide branch).
            // The Grid bottom-right cell stays an empty placeholder so
            // metric-cell row alignment isn't broken by a non-metric pill.
            VStack(alignment: .leading, spacing: LeafSpace.sm) {
                Grid(alignment: .topLeading, horizontalSpacing: LeafSpace.lg, verticalSpacing: LeafSpace.md) {
                    GridRow {
                        metricCell(value: focusValue, label: "focused")
                        metricCell(value: aiRatioValue, label: "AI ratio")
                    }
                    GridRow {
                        metricCell(value: "\(metrics.sessionsCount)", label: "sessions")
                        metricCell(value: "\(metrics.switchCount)", label: "switches")
                    }
                    GridRow {
                        metricCell(value: "\(metrics.commitsCount)", label: "commits")
                        Color.clear
                            .frame(width: 1, height: 1)
                            .accessibilityHidden(true)
                    }
                }
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    YouNowStateBadge(state: youNowState)
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
}
