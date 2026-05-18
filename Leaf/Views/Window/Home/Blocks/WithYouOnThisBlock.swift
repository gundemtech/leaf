//
//  WithYouOnThisBlock.swift
//  Track 8 / Phase 8.2 — Home layout shell. Placeholder body until
//  Phase 8.5 wires `DerivedInsights.sameTaskTeammates(rule:.hierarchical)`
//  + confidence badges + offline footer + Team CTA. Phase 8.1 substrate
//  already shipped: `TeammateMatch`, `SameTaskMatcher`,
//  `TeammatePresenceReader` (stub until Phase 5.4).
//

import LeafCore
import SwiftUI

struct WithYouOnThisBlock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("WITH YOU ON THIS")
                .leafSectionLabel()
                .foregroundStyle(LeafColor.text.tertiary)

            LeafCard(padding: .regular) {
                LeafEmptyState(
                    icon: LeafIcons.brand.leaf,
                    title: "Teammates on this task",
                    description: "Anyone working on the same Linear issue, branch, or adjacent branch will appear here."
                )
            }
        }
    }
}
