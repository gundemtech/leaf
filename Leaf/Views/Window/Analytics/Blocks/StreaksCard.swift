//
//  StreaksCard.swift
//  Track-9 T9 — 5 streak rows в single LeafCard. SF Symbol icon +
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
        .accessibilityLabel(accessibilitySummary)
    }

    // T10 a11y IMPORTANT-3: provide explicit summary label so VoiceOver
    // narrates "Streaks: Commits 3 days, Issues closed 1 day…" with header
    // context instead of bare concatenated row text.
    private var accessibilitySummary: String {
        var parts: [String] = ["Streaks"]
        parts.append("Commits \(streakText(metrics.commitStreak))")
        parts.append("Issues closed \(streakText(metrics.issueCloseStreak))")
        parts.append("Huddles \(streakText(metrics.huddleStreak))")
        parts.append("Focus sessions \(streakText(metrics.focusSessionStreak))")
        parts.append("Heavy days \(streakText(metrics.heavyPulseStreak))")
        return parts.joined(separator: ", ")
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
