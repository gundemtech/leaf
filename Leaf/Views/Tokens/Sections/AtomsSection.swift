//
//  AtomsSection.swift
//  Track 2 / D1 — Stub. Filled by Tasks 11–14: LeafIcon, LeafDot, LeafDivider, LeafSpacer.
//

import SwiftUI

#if DEBUG
struct AtomsSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.lg) {
            Text("Atoms").font(LeafType.title.large).foregroundStyle(LeafColor.text.primary)
            Text("Pending — populated by Track 2/D1 Tasks 11–14")
                .font(LeafType.body.small).foregroundStyle(LeafColor.text.tertiary)
        }
    }
}
#endif
