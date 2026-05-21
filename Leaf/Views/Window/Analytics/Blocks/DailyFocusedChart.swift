//
//  DailyFocusedChart.swift
//  Track-9 T9 — SwiftUI Charts BarMark (focused-min primary Y) +
//  LineMark (aiRatio rendered as 0..100% for visual co-presence)
//  dual-metric chart over 7 days. First Charts usage in codebase.
//  macOS 14+ target supports.
//

import Charts
import LeafCore
import SwiftUI

struct DailyFocusedChart: View {
    let days: [DailyMetric]

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        formatter.locale = .current
        return formatter
    }()

    var body: some View {
        LeafCard(padding: .regular) {
            VStack(alignment: .leading, spacing: LeafSpace.sm) {
                Text("FOCUS THIS WEEK")
                    .leafSectionLabel()
                chart
                    .frame(height: 200)
                legend
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var chart: some View {
        Chart {
            ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                BarMark(
                    x: .value("Day", weekdayLabel(day.dayStartMs)),
                    y: .value("Focused", day.focusedMin)
                )
                .foregroundStyle(LeafColor.accent.primary)
            }
            ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                LineMark(
                    x: .value("Day", weekdayLabel(day.dayStartMs)),
                    y: .value("AI ratio", day.aiRatio * 100),
                    series: .value("Metric", "AI")
                )
                .foregroundStyle(LeafColor.status.info)
                .symbol(Circle().strokeBorder(lineWidth: 1.5))
                .symbolSize(36)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic) { _ in
                AxisValueLabel()
                    .font(LeafType.label)
                    .foregroundStyle(LeafColor.text.tertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(LeafColor.border.subtle)
                AxisValueLabel()
                    .font(LeafType.label)
                    .foregroundStyle(LeafColor.text.tertiary)
            }
        }
    }

    private var legend: some View {
        HStack(spacing: LeafSpace.md) {
            legendDot(color: LeafColor.accent.primary, label: "Focused (min)")
            legendDot(color: LeafColor.status.info, label: "AI ratio (%)")
        }
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: LeafSpace.xs) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(LeafType.label)
                .foregroundStyle(LeafColor.text.tertiary)
        }
    }

    private func weekdayLabel(_ dayStartMs: Int64) -> String {
        guard dayStartMs > 0 else { return "—" }
        let date = Date(timeIntervalSince1970: TimeInterval(dayStartMs) / 1000.0)
        return Self.weekdayFormatter.string(from: date)
    }

    private var accessibilityLabel: String {
        let totalMin = days.reduce(0) { $0 + $1.focusedMin }
        let avgRatio = days.isEmpty ? 0 : days.reduce(0.0) { $0 + $1.aiRatio } / Double(days.count)
        return "Focus this week: \(totalMin) minutes total, AI ratio average \(Int(round(avgRatio * 100))) percent."
    }
}
