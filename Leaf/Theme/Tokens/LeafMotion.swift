//
//  LeafMotion.swift
//  Track 2 / D1 — Tier 2 motion tokens. Springs, durations, easings.
//  reduceMotion fallback — all animations collapse to .linear(duration: 0).
//  Consumers apply via .leafAnimation(LeafMotion.spring.gentle, value: ...).
//

import SwiftUI

enum LeafMotion {
    enum duration {
        static let snap:   Double = 0.12
        static let short:  Double = 0.20
        static let medium: Double = 0.35
        static let long:   Double = 0.55
    }

    enum spring {
        static let snappy = Animation.interactiveSpring(response: 0.20, dampingFraction: 0.85)
        static let gentle = Animation.interactiveSpring(response: 0.45, dampingFraction: 0.80)
        static let bouncy = Animation.bouncy(duration: 0.50, extraBounce: 0.10)
    }

    enum easing {
        static let standard   = Animation.timingCurve(0.25, 0.10, 0.25, 1.00, duration: duration.medium)
        static let emphasized = Animation.timingCurve(0.20, 0.00, 0.00, 1.00, duration: duration.medium)
    }
}

extension View {
    /// Apply a Leaf motion token, honouring accessibilityReduceMotion.
    /// `value` triggers re-evaluation; same semantics as native .animation(_:value:).
    func leafAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(LeafAnimationModifier(animation: animation, value: value))
    }
}

private struct LeafAnimationModifier<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? .linear(duration: 0) : animation, value: value)
    }
}
