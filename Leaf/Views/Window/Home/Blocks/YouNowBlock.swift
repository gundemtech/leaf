//
//  YouNowBlock.swift
//  Track 8 / Phase 8.2 — Home layout shell. Placeholder body until
//  Phase 8.4 wires `DerivedInsights.youNowState(now:)` + 4-state visual
//  (active / inMeeting / deepWorkFocus / away). Phase 8.1 substrate
//  already shipped: `YouNowState`, `YouNowStateDeriver`.
//

import LeafCore
import SwiftUI

struct YouNowBlock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("YOU · NOW")
                .leafSectionLabel()
                .foregroundStyle(LeafColor.text.tertiary)

            LeafCard(padding: .regular) {
                LeafEmptyState(
                    icon: LeafIcons.brand.leaf,
                    title: "Your current state",
                    description: "Active app, file, branch, and intensity will appear here."
                )
            }
        }
    }
}
