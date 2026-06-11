//
//  TodayBlock.swift
//  Home redesign — glanceable TODAY snapshot with a visual hierarchy:
//  focused time is the headline number, the remaining metrics (AI ratio /
//  sessions / switches / commits) read as a secondary strip, and a 7-day
//  focus sparkline (Swift Charts BarMark over `weeklyMetrics.dailySeries`,
//  today highlighted) gives the day a trend context. The YOU·NOW badge
//  moved to the NOW hero (current state belongs next to current work).
//

import Charts
import LeafCore
import SwiftUI

struct TodayBlock: View {
    let metrics: TodayMetrics
    let weekly: WeeklyMetrics

    /// Cached locale-aware "EEE d MMM" formatter so the "TODAY · <date>"
    /// label doesn't allocate a `DateFormatter` per body re-eval.
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
                    content
                }
            }
        }
    }

    private var sectionLabel: String {
        "TODAY · \(Self.sectionDateFormatter.string(from: Date()))"
    }

    // MARK: - Content

    private var content: some View {
        ViewThatFits(in: .horizontal) {
            // Wide branch — headline + secondary strip left, sparkline right.
            HStack(alignment: .top, spacing: LeafSpace.xl) {
                VStack(alignment: .leading, spacing: LeafSpace.md) {
                    headlineCell
                    secondaryStrip
                }
                Spacer(minLength: 0)
                sparkline
                    .frame(width: 180, height: 64)
            }
            // Narrow branch — stacked.
            VStack(alignment: .leading, spacing: LeafSpace.md) {
                headlineCell
                secondaryStrip
                sparkline
                    .frame(maxWidth: .infinity)
                    .frame(height: 64)
            }
        }
    }

    private var headlineCell: some View {
        VStack(alignment: .leading, spacing: LeafSpace.xxs) {
            Text(focusValue)
                .font(LeafType.title.large.monospacedDigit())
                .foregroundStyle(LeafColor.text.primary)
            Text("focused today")
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(focusValue) focused today")
    }

    private var secondaryStrip: some View {
        HStack(alignment: .top, spacing: LeafSpace.lg) {
            metricCell(value: aiRatioValue, label: "AI ratio")
            metricCell(value: "\(metrics.sessionsCount)", label: "sessions")
            metricCell(value: "\(metrics.switchCount)", label: "switches")
            metricCell(value: "\(metrics.commitsCount)", label: "commits")
        }
    }

    private func metricCell(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: LeafSpace.xxs) {
            Text(value)
                .font(LeafType.body.large.monospacedDigit())
                .foregroundStyle(LeafColor.text.primary)
            Text(label)
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(label)")
    }

    // MARK: - Sparkline

    /// 7-day focus bars, today emphasized. Axes hidden — a trend glance,
    /// not an analytics surface (the Analytics tab owns the full chart).
    @ViewBuilder
    private var sparkline: some View {
        let days = weekly.dailySeries
        if days.contains(where: { $0.focusedMin > 0 }) {
            VStack(alignment: .trailing, spacing: LeafSpace.xxs) {
                Chart {
                    ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                        BarMark(
                            x: .value("Day", index),
                            y: .value("Focused", max(day.focusedMin, 1))
                        )
                        .foregroundStyle(
                            index == days.count - 1
                                ? LeafColor.accent.primary
                                : LeafColor.accent.primary.opacity(0.3)
                        )
                        .cornerRadius(LeafRadius.sm / 2)
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                Text("last 7 days")
                    .font(LeafType.label)
                    .foregroundStyle(LeafColor.text.quaternary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(sparklineA11yLabel)
        }
    }

    private var sparklineA11yLabel: String {
        let total = weekly.dailySeries.reduce(0) { $0 + $1.focusedMin }
        return "Focus trend, last 7 days, \(total) minutes total."
    }

    // MARK: - Formatting

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
