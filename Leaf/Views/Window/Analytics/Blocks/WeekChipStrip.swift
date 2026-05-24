//
//  WeekChipStrip.swift
//  Track-9 T9 — 7 horizontal day chips from WeeklyMetrics.dailySeries.
//  Today (dailySeries[6]) highlighted with accent.primary background.
//  Substrate fidelity: 7 chips, NOT 8 (master spec amendment T10).
//

import LeafCore
import SwiftUI

struct WeekChipStrip: View {
    let days: [DailyMetric]

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        formatter.locale = .current
        return formatter
    }()

    private static let fullWeekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        formatter.locale = .current
        return formatter
    }()

    var body: some View {
        HStack(spacing: LeafSpace.sm) {
            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                chip(day: day, isToday: index == days.count - 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(day: DailyMetric, isToday: Bool) -> some View {
        VStack(spacing: LeafSpace.xxs) {
            Text(weekdayLabel(day.dayStartMs))
                .font(LeafType.label)
                .foregroundStyle(isToday ? LeafColor.text.inverse : LeafColor.text.tertiary)
            Text(focusedLabel(day.focusedMin))
                .font(LeafType.body.regular)
                .foregroundStyle(isToday ? LeafColor.text.inverse : LeafColor.text.primary)
        }
        .padding(.vertical, LeafSpace.sm)
        .padding(.horizontal, LeafSpace.md)
        .frame(minWidth: 56)
        .background(
            RoundedRectangle(cornerRadius: LeafRadius.sm)
                .fill(isToday ? LeafColor.accent.primary : LeafColor.surface.inset)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(fullWeekdayLabel(day.dayStartMs)) \(focusedLabel(day.focusedMin))\(isToday ? ", today" : "")"
        )
    }

    private func weekdayLabel(_ dayStartMs: Int64) -> String {
        guard dayStartMs > 0 else { return "—" }
        let date = Date(timeIntervalSince1970: TimeInterval(dayStartMs) / 1000.0)
        return Self.weekdayFormatter.string(from: date)
    }

    private func fullWeekdayLabel(_ dayStartMs: Int64) -> String {
        guard dayStartMs > 0 else { return "Day" }
        let date = Date(timeIntervalSince1970: TimeInterval(dayStartMs) / 1000.0)
        return Self.fullWeekdayFormatter.string(from: date)
    }

    private func focusedLabel(_ min: Int) -> String {
        guard min > 0 else { return "—" }
        return "\(min)m"
    }
}
