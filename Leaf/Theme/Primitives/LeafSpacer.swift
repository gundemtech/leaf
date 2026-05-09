//
//  LeafSpacer.swift
//  Track 2 / D1 — Atom A4. Semantic wrapper над `Spacer`.
//  Fixed-size: `LeafSpacer(LeafSpace.lg)` renders a `Color.clear` square.
//  Flexible: `LeafSpacer()` renders `Spacer(minLength: 0)`.
//

import SwiftUI

struct LeafSpacer: View {
    let size: CGFloat?

    init(_ space: CGFloat) { self.size = space }
    init() { self.size = nil }

    var body: some View {
        if let size {
            Color.clear.frame(width: size, height: size)
        } else {
            Spacer(minLength: 0)
        }
    }
}
