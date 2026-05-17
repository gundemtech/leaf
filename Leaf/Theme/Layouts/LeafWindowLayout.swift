//
//  LeafWindowLayout.swift
//  Track 2 / D1 — Template T1. NavigationSplitView wrapper with consistent
//  paddings (sidebar only after D2 tweak), canvas background, and tunable
//  sidebar column widths via LeafWindowLayoutTokens.
//
//  D2 deviation: detail closure used to wrap content in `.padding(LeafSpace.xl)`.
//  After Track 2 D2 — chrome padding is per-view concern (HomeView owns its
//  own outer padding; D3/D4 not-yet-migrated views own theirs to avoid
//  double-padding stacks during snapshot-replacement migration).
//

import SwiftUI

struct LeafWindowLayout<Sidebar: View, Detail: View>: View {
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        NavigationSplitView {
            sidebar()
                .padding(.horizontal, LeafSpace.sm)
                .padding(.vertical, LeafSpace.md)
                .navigationSplitViewColumnWidth(
                    min: LeafWindowLayoutTokens.sidebarMinWidth,
                    ideal: LeafWindowLayoutTokens.sidebarIdealWidth,
                    max: LeafWindowLayoutTokens.sidebarMaxWidth
                )
        } detail: {
            detail()
        }
        .background(LeafColor.surface.canvas)
    }
}
