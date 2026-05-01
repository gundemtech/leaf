import SwiftUI

/// Wraps adjacent glass surfaces so their effects interpolate on macOS 26+.
/// On older macOS, falls back to a plain Group with no visual change.
struct LeafGlassGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder var content: () -> Content

    init(spacing: CGFloat = 16, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

/// Primary CTA wrapper — `.glassProminent` on macOS 26+, `.borderedProminent` fallback.
/// Use instead of `.buttonStyle(.glassProminent)` directly to avoid scattered availability
/// checks.
struct LeafProminentButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder var label: () -> Label

    init(action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Label) {
        self.action = action
        self.label = label
    }

    var body: some View {
        if #available(macOS 26, *) {
            Button(action: action, label: label)
                .buttonStyle(.glassProminent)
                .tint(.leafAccent)
        } else {
            Button(action: action, label: label)
                .buttonStyle(.borderedProminent)
                .tint(.leafAccent)
        }
    }
}

/// Secondary CTA — `.glass` on macOS 26+, `.bordered` fallback.
struct LeafSecondaryButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder var label: () -> Label

    init(action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Label) {
        self.action = action
        self.label = label
    }

    var body: some View {
        if #available(macOS 26, *) {
            Button(action: action, label: label)
                .buttonStyle(.glass)
        } else {
            Button(action: action, label: label)
                .buttonStyle(.bordered)
        }
    }
}
