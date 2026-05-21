//
//  WoWDeltaCallout.swift
//  Track-9 T9 — Week-over-week delta callout. Sparkline (7-point
//  LineMark from dailySeries.focusedMin) + formatted delta text
//  ("+12%" / "-8%" / "—" if nil). Tone-coded: success / warning /
//  tertiary nil-graceful.
//

import Charts
import LeafCore
import SwiftUI

struct WoWDeltaCallout: View {
    let delta: Double?
    let dailySeries: [DailyMetric]

    var body: some View {
        LeafCard(padding: .regular) {
            HStack(spacing: LeafSpace.lg) {
                // T10 a11y IMPORTANT-2: hide decorative sparkline Chart from
                // VoiceOver — parent `.accessibilityLabel` summarizes delta
                // direction + magnitude ("up 12 percent"); Chart with no
                // axis labels would otherwise emit per-LineMark "value 12,
                // value 18…" announcements.
                sparkline
                    .frame(width: 160, height: 40)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                    Text(deltaText)
                        .font(LeafType.title.medium)
                        .foregroundStyle(deltaTone)
                    Text("vs last week")
                        .font(LeafType.label)
                        .foregroundStyle(LeafColor.text.tertiary)
                }
                Spacer()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var sparkline: some View {
        Chart {
            ForEach(Array(dailySeries.enumerated()), id: \.offset) { idx, day in
                LineMark(
                    x: .value("Day", idx),
                    y: .value("Focused", day.focusedMin)
                )
                .foregroundStyle(LeafColor.accent.primary)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
    }

    private var deltaText: String {
        guard let d = delta else { return "—" }
        let pct = Int(round(d * 100))
        return String(format: "%+d%%", pct)
    }

    private var deltaTone: Color {
        guard let d = delta else { return LeafColor.text.tertiary }
        if d > 0 { return LeafColor.status.success }
        if d < 0 { return LeafColor.status.warning }
        return LeafColor.text.secondary
    }

    private var accessibilityLabel: String {
        guard let d = delta else {
            return "Week over week delta: not enough data yet."
        }
        let pct = Int(round(d * 100))
        let direction = d > 0 ? "up" : (d < 0 ? "down" : "flat")
        return "Week over week focus minutes: \(direction) \(abs(pct)) percent."
    }
}
