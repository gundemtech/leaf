//
//  TopToolsPlaceholder.swift
//  Track-9 T9 — Honest "Coming soon" placeholder. Substrate gap
//  per T4 D-1 deviation: topToolsWeek field deferred to T6 SurfacePill
//  discriminator refactor (post-Track-9 phase). Better UX than skip —
//  preserves master spec §3.5 6-component shape commitment.
//

import LeafCore
import SwiftUI

struct TopToolsPlaceholder: View {
    var body: some View {
        LeafCard(padding: .regular) {
            LeafEmptyState(
                icon: LeafIcons.brand.leaf,
                title: "Top tools — coming soon",
                description: "Week-scoped tools breakdown lands in the next phase."
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Top tools placeholder. Week-scoped tools breakdown coming in a future phase.")
    }
}
