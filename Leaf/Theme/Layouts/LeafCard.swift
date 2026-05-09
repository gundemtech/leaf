//
//  LeafCard.swift
//  Track 2 / D1 — Organism O1. Container with header / content / footer slots
//  + variant (rest/raised/glass) + padding preset (tight/regular/generous).
//
//  Deviation from plan §2587: plan's `.glass` background is Color.clear with a
//  TODO that consumer applies .leafGlass externally. This makes the card
//  fragile and unergonomic — apply .leafGlass(.regular, cornerRadius: LeafRadius.lg)
//  inside the card itself when variant == .glass. T3 still exposes
//  LeafCardTokens.Variant.glass — this is a pure rendering refinement.
//

import SwiftUI

struct LeafCard<Header: View, Footer: View, Content: View>: View {
    var variant: LeafCardTokens.Variant = .raised
    var padding: LeafCardTokens.PaddingPreset = .regular
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            header()
            content()
            footer()
        }
        .padding(padding.pt)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
        .leafElevation(variant == .raised ? LeafElevation.raised : LeafElevation.flat)
    }

    @ViewBuilder
    private var background: some View {
        switch variant {
        case .rest:
            Color.clear
        case .raised:
            RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous)
                .fill(LeafColor.surface.raised)
        case .glass:
            Color.clear
                .leafGlass(.regular, cornerRadius: LeafRadius.lg)
        }
    }
}

extension LeafCard where Header == EmptyView, Footer == EmptyView {
    init(
        variant: LeafCardTokens.Variant = .raised,
        padding: LeafCardTokens.PaddingPreset = .regular,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.variant = variant
        self.padding = padding
        self.header = { EmptyView() }
        self.content = content
        self.footer = { EmptyView() }
    }
}
