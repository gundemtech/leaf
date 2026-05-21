//
//  AnalyticsContent.swift
//  Track-9 T9 — Analytics surface consumer. Receives WeeklyMetrics
//  (single-purpose, not full InsightsSnapshot) и composes 6 child
//  blocks per master spec §3.5. Empty-state branch via
//  `metrics == .empty` Equatable check (auto-synth WeeklyMetrics).
//

import LeafCore
import SwiftUI

struct AnalyticsContent: View {
    let metrics: WeeklyMetrics

    var body: some View {
        Group {
            if metrics == .empty {
                emptyState
            } else {
                populated
            }
        }
        .animation(.easeInOut(duration: 0.25), value: metrics)
    }

    private var emptyState: some View {
        LeafCard(padding: .regular) {
            LeafEmptyState(
                icon: LeafIcons.brand.leaf,
                title: "Not enough data yet",
                description: "Keep working and check back tomorrow."
            )
        }
    }

    private var populated: some View {
        VStack(alignment: .leading, spacing: LeafSpace.xl) {
            WeekChipStrip(days: metrics.dailySeries)
            DailyFocusedChart(days: metrics.dailySeries)
            HStack(alignment: .top, spacing: LeafSpace.lg) {
                StreaksCard(metrics: metrics)
                PeakHourCallout(peakHour: metrics.peakHour)
            }
            WoWDeltaCallout(delta: metrics.wowDelta, dailySeries: metrics.dailySeries)
            TopToolsPlaceholder()
        }
    }
}
