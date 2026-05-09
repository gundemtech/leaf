//
//  LeafToggle.swift
//  Track 2 / D1 — Molecule M5. Wraps native `Toggle(.switch)` with leaf accent
//  tint and LeafType label typography. Disabled state dims label to
//  LeafColor.text.quaternary.
//

import SwiftUI

struct LeafToggle: View {
    let title: String
    @Binding var isOn: Bool
    var disabled: Bool = false

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .font(LeafType.body.regular)
                .foregroundStyle(disabled ? LeafColor.text.quaternary : LeafColor.text.primary)
        }
        .toggleStyle(.switch)
        .tint(LeafColor.accent.primary)
        .disabled(disabled)
    }
}
