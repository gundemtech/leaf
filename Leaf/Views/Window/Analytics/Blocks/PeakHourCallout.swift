//
//  PeakHourCallout.swift
//  Track-9 T9 — 24-dot strip + peak hour highlighted. Substrate ships
//  only peakHour: Int?, no per-hour distribution. Single peak position
//  visualized; no fake density grading.
//

import LeafCore
import SwiftUI

struct PeakHourCallout: View {
    let peakHour: Int?

    var body: some View {
        LeafCard(padding: .regular) {
            VStack(alignment: .leading, spacing: LeafSpace.sm) {
                Text("PEAK HOUR").leafSectionLabel()
                // T10 a11y IMPORTANT-1: hide decorative 24-Capsule strip + tick
                // labels from VoiceOver — parent `.accessibilityLabel`
                // summarizes the peak hour already, no value in narrating each
                // of 24 capsules + axis ticks.
                dotStrip.accessibilityHidden(true)
                hourLabels.accessibilityHidden(true)
                Text(peakHourLabel)
                    .font(LeafType.title.medium)
                    .foregroundStyle(LeafColor.text.primary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var dotStrip: some View {
        HStack(spacing: 2) {
            ForEach(0..<24, id: \.self) { hour in
                Capsule()
                    .fill(hour == peakHour ? LeafColor.accent.primary : LeafColor.text.tertiary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 12)
            }
        }
    }

    private var hourLabels: some View {
        HStack(spacing: 0) {
            Text("0").font(LeafType.label).foregroundStyle(LeafColor.text.tertiary)
            Spacer()
            Text("6").font(LeafType.label).foregroundStyle(LeafColor.text.tertiary)
            Spacer()
            Text("12").font(LeafType.label).foregroundStyle(LeafColor.text.tertiary)
            Spacer()
            Text("18").font(LeafType.label).foregroundStyle(LeafColor.text.tertiary)
            Spacer()
            Text("23").font(LeafType.label).foregroundStyle(LeafColor.text.tertiary)
        }
    }

    private var peakHourLabel: String {
        guard let hour = peakHour else { return "—" }
        return String(format: "%02d:00", hour)
    }

    private var accessibilityLabel: String {
        guard let hour = peakHour else {
            return "Peak hour: not enough data yet."
        }
        return "Peak hour: \(String(format: "%02d", hour)):00 — highest attention across the week."
    }
}
