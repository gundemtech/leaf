//
//  StreaksCard.swift
//  Track-9 T9 — 5 streak rows in a single LeafCard. SF Symbol icon +
//  label + count per row. "—" for zero, "N day(s)" for positive.
//

import LeafCore
import SwiftUI

struct StreaksCard: View {
    let metrics: WeeklyMetrics

    var body: some View {
        LeafCard(padding: .regular) {
            VStack(alignment: .leading, spacing: LeafSpace.sm) {
                Text("STREAKS").leafSectionLabel()
                streakRow(
                    icon: "chevron.left.forwardslash.chevron.right",
                    label: "Commits",
                    count: metrics.commitStreak
                )
                streakRow(
                    icon: "checkmark.circle.fill",
                    label: "Issues closed",
                    count: metrics.issueCloseStreak
                )
                streakRow(
                    icon: "bubble.left.and.bubble.right.fill",
                    label: "Huddles",
                    count: metrics.huddleStreak
                )
                streakRow(
                    icon: "target",
                    label: "Focus sessions",
                    count: metrics.focusSessionStreak
                )
                streakRow(
                    icon: "flame.fill",
                    label: "Heavy days",
                    count: metrics.heavyPulseStreak
                )
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func streakRow(icon: String, label: String, count: Int) -> some View {
        HStack(spacing: LeafSpace.sm) {
            Image(systemName: icon)
                .foregroundStyle(LeafColor.accent.primary)
                .frame(width: 20, alignment: .leading)
            Text(label)
                .font(LeafType.body.regular)
                .foregroundStyle(LeafColor.text.primary)
            Spacer()
            Text(streakText(count))
                .font(LeafType.body.regular)
                .foregroundStyle(LeafColor.text.secondary)
        }
    }

    private func streakText(_ count: Int) -> String {
        switch count {
        case 0: return "—"
        case 1: return "1 day"
        default: return "\(count) days"
        }
    }
}
