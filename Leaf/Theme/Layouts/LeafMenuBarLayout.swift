//
//  LeafMenuBarLayout.swift
//  Track 2 / D1 — Template T3. Fixed-width menu-bar popover wrapper on a
//  raised surface. Width surfaced via LeafMenuBarLayoutTokens.
//

import SwiftUI

struct LeafMenuBarLayout<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
                .padding(LeafSpace.md)
        }
        .frame(width: LeafMenuBarLayoutTokens.width)
        .background(LeafColor.surface.raised)
    }
}
