//
//  LeafSelect.swift
//  Track 2 / D1 — Molecule M7. Wraps native SwiftUI `Picker` with leaf accent
//  tint and LeafType.body.regular. SwiftUI `PickerStyle` is opaque and not
//  type-erasable, so body branches per variant directly (per plan §2435 note).
//  Combobox currently aliases .menu (editable variant deferred — D2 if needed).
//

import SwiftUI

struct LeafSelect<Value: Hashable & Identifiable, Content: View>: View {
    @Binding var selection: Value
    var variant: LeafSelectTokens.Variant = .dropdown
    let options: [Value]
    @ViewBuilder let label: (Value) -> Content

    @ViewBuilder
    var body: some View {
        switch variant {
        case .dropdown:
            picker
                .pickerStyle(.menu)
                .tint(LeafColor.accent.primary)
                .font(LeafType.body.regular)
        case .combobox:
            picker
                .pickerStyle(.menu)
                .tint(LeafColor.accent.primary)
                .font(LeafType.body.regular)
        case .segmented:
            picker
                .pickerStyle(.segmented)
                .tint(LeafColor.accent.primary)
                .font(LeafType.body.regular)
        }
    }

    private var picker: some View {
        Picker("", selection: $selection) {
            ForEach(options) { opt in
                label(opt).tag(opt)
            }
        }
        .labelsHidden()
    }
}
