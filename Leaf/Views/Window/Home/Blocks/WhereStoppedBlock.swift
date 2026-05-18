//
//  WhereStoppedBlock.swift
//  Track 8 / Phase 8.2 — Home layout shell. Placeholder body until
//  Phase 8.7 wires Track-1 D3 `WhereStoppedDeriver` snapshot + last
//  commit + click → existing `WorkStateDetailScreen` (Track-7 P3).
//

import LeafCore
import SwiftUI

struct WhereStoppedBlock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("WHERE YOU STOPPED")
                .leafSectionLabel()
                .foregroundStyle(LeafColor.text.tertiary)

            LeafCard(padding: .regular) {
                LeafEmptyState(
                    icon: LeafIcons.brand.leaf,
                    title: "Last work context",
                    description: "Your most recent stop-point and last commit will appear here."
                )
            }
        }
    }
}
