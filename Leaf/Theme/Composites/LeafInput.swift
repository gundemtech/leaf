//
//  LeafInput.swift
//  Track 2 / D1 — Molecule M6. Text input with rest/focus/error/disabled states.
//  Optional prefix icon. Border thickness 1pt rest, 2pt focus/error (raw int OK —
//  not a padding/radius/cornerRadius value, token guard untouched).
//

import SwiftUI

struct LeafInput: View {
    @Binding var text: String
    let placeholder: String
    var size: LeafInputTokens.Size = .md
    var prefixIcon: String? = nil
    var error: String? = nil
    var disabled: Bool = false

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.xs) {
            HStack(spacing: LeafSpace.sm) {
                if let prefixIcon {
                    LeafIcon(systemName: prefixIcon, size: .md, tint: LeafColor.text.tertiary)
                }
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .disabled(disabled)
                    .font(LeafType.body.regular)
                    .foregroundStyle(disabled ? LeafColor.text.quaternary : LeafColor.text.primary)
            }
            .padding(.horizontal, size.horizontalPadding)
            .frame(height: size.height)
            .background(
                RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
                    .fill(LeafColor.surface.canvas)
                    .overlay(
                        RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
                            .strokeBorder(borderColor, lineWidth: focused || error != nil ? 2 : 1)
                    )
            )
            .leafAnimation(LeafMotion.spring.snappy, value: focused)

            if let error {
                Text(error)
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.status.danger)
            }
        }
    }

    private var borderColor: Color {
        if disabled { return LeafColor.border.subtle }
        if error != nil { return LeafColor.status.danger }
        if focused { return LeafColor.border.focus }
        return LeafColor.border.strong
    }
}
