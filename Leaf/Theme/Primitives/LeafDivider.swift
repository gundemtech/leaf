//
//  LeafDivider.swift
//  Track 2 / D1 — Atom A3. Horizontal hairline separator.
//  Variants: hairline (1pt LeafColor.border.subtle) / soft (1pt @ 50% opacity).
//

import SwiftUI

enum LeafDividerStyle { case hairline, soft }

struct LeafDivider: View {
    var style: LeafDividerStyle = .hairline

    var body: some View {
        Rectangle()
            .fill(style == .soft
                  ? LeafColor.border.subtle.opacity(0.5)
                  : LeafColor.border.subtle)
            .frame(height: 1)
    }
}
