//
//  AnalyticsContent.swift
//  Track-9 T9 — Analytics surface consumer. Receives WeeklyMetrics
//  (single-purpose, not full InsightsSnapshot) and composes 6 child
//  blocks per master spec §3.5. Empty-state branch via
//  `metrics == .empty` Equatable check (auto-synth WeeklyMetrics).
//

import LeafCore
import SwiftUI

struct AnalyticsContent: View {
    let metrics: WeeklyMetrics

    var body: some View {
        Group {
            if isLogicallyEmpty {
                emptyState
            } else {
                populated
            }
        }
        .animation(.easeInOut(duration: 0.25), value: metrics)
    }

    /// Treats a real-substrate snapshot with populated `dayStartMs` but
    /// zero focus / commits / streaks / peakHour / wowDelta as "logically
    /// empty" for the AnalyticsContent empty-state UX. `WeeklyMetrics ==
    /// .empty` Equatable check alone fails on prod (`ProdInsights.+
    /// WeeklyMetrics` always writes real local-TZ midnight day boundaries
    /// even on a fresh cold DB — review IMP-1 fix).
    private var isLogicallyEmpty: Bool {
        guard metrics.peakHour == nil,
              metrics.wowDelta == nil,
              metrics.commitStreak == 0,
              metrics.issueCloseStreak == 0,
              metrics.huddleStreak == 0,
              metrics.focusSessionStreak == 0,
              metrics.heavyPulseStreak == 0
        else { return false }
        return metrics.dailySeries.allSatisfy { day in
            day.focusedMin == 0
                && day.sessionsCount == 0
                && day.commitsCount == 0
                && day.aiRatio == 0
        }
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
