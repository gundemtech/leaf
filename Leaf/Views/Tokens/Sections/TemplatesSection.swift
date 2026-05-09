//
//  TemplatesSection.swift
//  Track 2 / D1 — Stub. Filled by Tasks 39–42 (LeafWindow/Sheet/MenuBar/OnboardingStep layouts).
//

import SwiftUI

#if DEBUG
struct TemplatesSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.lg) {
            Text("Templates").font(LeafType.title.large).foregroundStyle(LeafColor.text.primary)
            Text("Pending — populated by Track 2/D1 Tasks 39–42")
                .font(LeafType.body.small).foregroundStyle(LeafColor.text.tertiary)
        }
    }
}
#endif
