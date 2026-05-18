//
//  TodayBlock.swift
//  Track 8 / Phase 8.2 — Home layout shell. Placeholder body until
//  Phase 8.3 wires `DerivedInsights.todayMetrics(now:)` (Phase 8.1
//  substrate already shipped: `TodayMetrics`, `SurfacePill`).
//

import LeafCore
import SwiftUI

struct TodayBlock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("TODAY")
                .leafSectionLabel()
                .foregroundStyle(LeafColor.text.tertiary)

            LeafCard(padding: .regular) {
                LeafEmptyState(
                    icon: LeafIcons.brand.leaf,
                    title: "Today metrics",
                    description: "Focused time, AI ratio, sessions, switches, and commits will appear here."
                )
            }
        }
    }
}
