//
//  LeafButton.swift
//  Track 2 / D1 — Molecule M1. Composes LeafButtonTokens.
//  Variants: primary / secondary / ghost / destructive.
//  Sizes: sm / md / lg. Optional leading icon (SF Symbol or Asset Catalog),
//  loading state replaces label with ProgressView and disables interaction.
//

import SwiftUI

struct LeafButton<Label: View>: View {
    enum IconRef {
        case system(String)
        case asset(String)
    }

    var variant: LeafButtonTokens.Variant = .primary
    var size: LeafButtonTokens.Size = .md
    var icon: IconRef? = nil
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
                    iconView
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

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .system(let name):
            Image(systemName: name)
        case .asset(let name):
            Image(name)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: LeafIconSize.sm.pt, height: LeafIconSize.sm.pt)
        case .none:
            EmptyView()
        }
    }
}

extension LeafButton where Label == Text {
    init(_ title: String,
         variant: LeafButtonTokens.Variant = .primary,
         size: LeafButtonTokens.Size = .md,
         icon: IconRef? = nil,
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
