//
//  LeafTogglePreview.swift
//  Track 2 / D1 — TokensPreview entry for Molecule M5 LeafToggle.
//

import SwiftUI

#if DEBUG
struct LeafTogglePreview: View {
    @State private var on = true
    @State private var off = false

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("LeafToggle").font(LeafType.title.medium).foregroundStyle(LeafColor.text.primary)

            VStack(alignment: .leading, spacing: LeafSpace.sm) {
                LeafToggle(title: "Share with team", isOn: $on)
                LeafToggle(title: "Allow notifications", isOn: $off)
                LeafToggle(title: "Read-only (disabled, on)", isOn: .constant(true), disabled: true)
                LeafToggle(title: "Read-only (disabled, off)", isOn: .constant(false), disabled: true)
            }

            TokensInlineSpec(
                spec: "LeafToggle · native .switch · tint LeafColor.accent.primary · LeafType.body.regular",
                codeSnippet: "LeafToggle(title: \"Share with team\", isOn: $isOn)"
            )
        }
        .padding(LeafSpace.lg)
        .background(LeafColor.surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
    }
}
#endif
