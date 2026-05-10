//
//  LeafWindowLayout.swift
//  Track 2 / D1 — Template T1. NavigationSplitView wrapper with consistent
//  paddings, canvas background, and tunable sidebar column widths via
//  LeafWindowLayoutTokens.
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
                    min:   LeafWindowLayoutTokens.sidebarMinWidth,
                    ideal: LeafWindowLayoutTokens.sidebarIdealWidth,
                    max:   LeafWindowLayoutTokens.sidebarMaxWidth
                )
        } detail: {
            detail()
                .padding(LeafSpace.xl)
        }
        .background(LeafColor.surface.canvas)
    }
}
