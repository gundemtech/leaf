import SwiftUI

/// Cream/paper card surface with optional Liquid Glass overlay (macOS 26+).
/// Use as a building block for metric cards, settings sections, info tiles.
struct GlassCard<Content: View>: View {
    var padding: CGFloat = 20
    var cornerRadius: CGFloat = 16
    var tint: Color = .clear
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.leafCard, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .leafGlass(tint: tint, cornerRadius: cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.leafMuted.opacity(0.18), lineWidth: 0.5)
            )
    }
}
