//
//  MoleculesSection.swift
//  Track 2 / D1 — Stub. Filled by Tasks 15–24.
//

import SwiftUI

#if DEBUG
struct MoleculesSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.lg) {
            Text("Molecules").font(LeafType.title.large).foregroundStyle(LeafColor.text.primary)
            Text("Pending — populated by Track 2/D1 Tasks 15–24")
                .font(LeafType.body.small).foregroundStyle(LeafColor.text.tertiary)
        }
    }
}
#endif
