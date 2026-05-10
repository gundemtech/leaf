//
//  LeafToolbar.swift
//  Track 2 / D1 — Organism O8. Top-bar with leading / center / trailing slots
//  separated by Spacers and bottom hairline. Background = canvas to anchor it
//  visually above scroll content. Used as the topmost element of every primary
//  surface (Activity / Team / Connections / Settings).
//

import SwiftUI

struct LeafToolbar<Leading: View, Center: View, Trailing: View>: View {
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let center: () -> Center
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: LeafToolbarTokens.slotSpacing) {
                leading()
                Spacer()
                center()
                Spacer()
                trailing()
            }
            .padding(.horizontal, LeafToolbarTokens.horizontalPadding)
            .padding(.vertical, LeafToolbarTokens.verticalPadding)
            LeafDivider()
        }
        .background(LeafColor.surface.canvas)
    }
}
