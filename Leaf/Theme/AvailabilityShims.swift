import SwiftUI

extension View {
    /// Liquid Glass on macOS 26+, `.ultraThinMaterial` fallback below.
    @ViewBuilder
    func leafGlass<S: Shape>(tint: Color = .clear, in shape: S) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular.tint(tint), in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }

    func leafGlass(tint: Color = .clear, cornerRadius: CGFloat = 16) -> some View {
        leafGlass(tint: tint, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
