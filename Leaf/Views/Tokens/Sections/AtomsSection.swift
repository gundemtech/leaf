//
//  AtomsSection.swift
//  Track 2 / D1 — Filled by Tasks 11–14: LeafIcon, LeafDot, LeafDivider, LeafSpacer.
//

import SwiftUI

#if DEBUG
struct AtomsSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.xl) {
            Text("Atoms").font(LeafType.title.large).foregroundStyle(LeafColor.text.primary)
            LeafIconPreview()
            LeafDotPreview()
        }
    }
}
#endif
