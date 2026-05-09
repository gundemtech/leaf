//
//  LeafProgress.swift
//  Track 2 / D1 — Organism O10. Progress indicator — linear or circular,
//  determinate (`Double` 0…1) or indeterminate (`nil`). Wraps SwiftUI's native
//  ProgressView so reduce-motion + accessibility are handled by the system
//  rather than re-implemented atop Circle().trim+rotation.
//

import SwiftUI

struct LeafProgress: View {
    var style: LeafProgressTokens.Style = .linear
    var value: Double? = nil  // nil → indeterminate

    var body: some View {
        switch style {
        case .linear:
            ProgressView(value: value)
                .progressViewStyle(.linear)
                .tint(LeafColor.accent.primary)
                .frame(height: LeafProgressTokens.linearHeight)
        case .circular(let size):
            ProgressView(value: value)
                .progressViewStyle(.circular)
                .tint(LeafColor.accent.primary)
                .frame(width: size.pt, height: size.pt)
        }
    }
}
