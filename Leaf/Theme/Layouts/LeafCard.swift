//
//  LeafCard.swift
//  Track 2 / D1 — Organism O1. Container with header / content / footer slots
//  + variant (rest/raised/glass) + padding preset (tight/regular/generous).
//  All variants carry a LeafColor.border.subtle hairline so the card reads
//  as a defined surface on any background; raised + glass also carry an
//  elevation shadow so they lift off the canvas. Per-slot gaps separate
//  header→content (tight) from content→footer (looser).
//
//  Deviation from plan §2587: plan's `.glass` background is Color.clear with a
//  TODO that consumer applies .leafGlass externally. This makes the card
//  fragile and unergonomic — apply .leafGlass(.regular, cornerRadius: ...)
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
        VStack(alignment: .leading, spacing: 0) {
            header()
                .frame(maxWidth: .infinity, alignment: .leading)
            if Header.self != EmptyView.self {
                Spacer().frame(height: LeafCardTokens.headerContentGap)
            }
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
            if Footer.self != EmptyView.self {
                Spacer().frame(height: LeafCardTokens.contentFooterGap)
                footer()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(padding.pt)
        .background(background)
        .overlay(
            RoundedRectangle(cornerRadius: LeafCardTokens.cornerRadius, style: .continuous)
                .strokeBorder(LeafCardTokens.borderColor, lineWidth: LeafCardTokens.borderWidth)
        )
        .clipShape(RoundedRectangle(cornerRadius: LeafCardTokens.cornerRadius, style: .continuous))
        .leafElevation(variant.elevation)
    }

    @ViewBuilder
    private var background: some View {
        switch variant {
        case .rest:
            Color.clear
        case .raised:
            RoundedRectangle(cornerRadius: LeafCardTokens.cornerRadius, style: .continuous)
                .fill(LeafColor.surface.raised)
        case .glass:
            Color.clear
                .leafGlass(.regular, cornerRadius: LeafCardTokens.cornerRadius)
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
