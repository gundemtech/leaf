//
//  LeafGlass.swift
//  Track 2 / D1 — Tier 2 glass material tokens. macOS 26 path uses
//  .glassEffect; macOS 14/15 fallback uses Material. Consumers apply
//  .leafGlass(.regular, in: shape). EnvironmentKey forceLegacyGlass forces
//  fallback path for side-by-side preview on macOS 26 (TokensPreview only).
//

import SwiftUI

enum LeafGlass {
    case thin
    case regular
    case thick
    case accentTinted
}

private struct ForceLegacyGlassKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var forceLegacyGlass: Bool {
        get { self[ForceLegacyGlassKey.self] }
        set { self[ForceLegacyGlassKey.self] = newValue }
    }
}

extension View {
    /// Apply a glass surface. macOS 26 — Liquid Glass; macOS 14/15 —
    /// Material fallback. `forceLegacyGlass` env value pins to fallback even on 26.
    func leafGlass<S: Shape>(_ variant: LeafGlass, in shape: S) -> some View {
        modifier(LeafGlassModifier(variant: variant, shape: AnyShape(shape)))
    }

    /// Convenience overload — RoundedRectangle from a LeafRadius value.
    func leafGlass(_ variant: LeafGlass, cornerRadius: CGFloat = LeafRadius.lg) -> some View {
        leafGlass(variant, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct LeafGlassModifier: ViewModifier {
    let variant: LeafGlass
    let shape: AnyShape
    @Environment(\.forceLegacyGlass) private var forceLegacy

    func body(content: Content) -> some View {
        if #available(macOS 26, *), !forceLegacy {
            modernGlass(content)
        } else {
            legacyGlass(content)
        }
    }

    @available(macOS 26, *)
    @ViewBuilder
    private func modernGlass(_ content: Content) -> some View {
        switch variant {
        case .thin:
            content.glassEffect(.regular, in: shape).opacity(0.5)
        case .regular:
            content.glassEffect(.regular, in: shape)
        case .thick:
            content.glassEffect(.regular.interactive(), in: shape)
        case .accentTinted:
            content.glassEffect(.regular.tint(LeafColor.surface.glassTint), in: shape)
        }
    }

    @ViewBuilder
    private func legacyGlass(_ content: Content) -> some View {
        switch variant {
        case .thin:
            content.background(.ultraThinMaterial, in: shape)
        case .regular:
            content.background(.regularMaterial, in: shape)
        case .thick:
            content.background(.thickMaterial, in: shape)
        case .accentTinted:
            content
                .background(.regularMaterial, in: shape)
                .overlay(LeafColor.surface.glassTint.clipShape(shape))
        }
    }
}
