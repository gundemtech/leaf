//
//  LeafButton.swift
//  Track 2 / D1 — Molecule M1. Composes LeafButtonTokens.
//  Variants: primary / secondary / ghost / destructive.
//  Sizes: sm / md / lg. Optional leading icon, loading state replaces label
//  with ProgressView and disables interaction.
//

import SwiftUI

struct LeafButton<Label: View>: View {
    var variant: LeafButtonTokens.Variant = .primary
    var size: LeafButtonTokens.Size = .md
    var icon: String? = nil
    var isLoading: Bool = false
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: LeafSpace.sm) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(LeafButtonTokens.Foreground.resting(variant))
                } else {
                    if let icon { Image(systemName: icon) }
                    label()
                }
            }
            .font(size.font)
            .foregroundStyle(LeafButtonTokens.Foreground.resting(variant))
            .padding(.horizontal, size.horizontalPadding)
            .frame(height: size.height)
            .background(
                RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
                    .fill(isHovering
                          ? LeafButtonTokens.Background.hover(variant)
                          : LeafButtonTokens.Background.resting(variant))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .leafAnimation(LeafMotion.spring.snappy, value: isHovering)
        .disabled(isLoading)
    }
}

extension LeafButton where Label == Text {
    init(_ title: String,
         variant: LeafButtonTokens.Variant = .primary,
         size: LeafButtonTokens.Size = .md,
         icon: String? = nil,
         isLoading: Bool = false,
         action: @escaping () -> Void) {
        self.variant = variant
        self.size = size
        self.icon = icon
        self.isLoading = isLoading
        self.action = action
        self.label = { Text(title) }
    }
}
