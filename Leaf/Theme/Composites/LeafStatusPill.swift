//
//  LeafStatusPill.swift
//  Track 2 / D1 — Organism O5. Animated presence chip — dot + label inside
//  capsule. States: idle / active / sharing / invisible. `active` and `sharing`
//  pulse a halo ring around the dot. Reduce-motion-respecting (the pulse
//  withAnimation(...repeatForever) is gated on accessibilityReduceMotion).
//

import SwiftUI

enum LeafStatusPillState {
    case idle, active, sharing, invisible

    var dotTone: LeafDotTone {
        switch self {
        case .idle: .muted
        case .active: .accent
        case .sharing: .info
        case .invisible: .muted
        }
    }

    var label: String {
        switch self {
        case .idle: "Idle"
        case .active: "Active"
        case .sharing: "Sharing"
        case .invisible: "Invisible"
        }
    }

    var pulses: Bool { self == .active || self == .sharing }
}

struct LeafStatusPill: View {
    let state: LeafStatusPillState

    @Environment(\.accessibilityReduceMotion) private var systemReduce
    @Environment(\.leafReduceMotionOverride) private var debugReduce
    @State private var pulse = false

    var body: some View {
        HStack(spacing: LeafSpace.xs) {
            ZStack {
                if state.pulses {
                    Circle()
                        .stroke(state.dotTone.color, lineWidth: LeafStatusPillTokens.pulseRingWidth)
                        .scaleEffect(pulse ? LeafStatusPillTokens.pulseScale : 1.0)
                        .opacity(pulse ? 0 : 0.6)
                        .frame(
                            width: LeafStatusPillTokens.pulseRingSize,
                            height: LeafStatusPillTokens.pulseRingSize
                        )
                }
                LeafDot(tone: state.dotTone, size: .sm)
            }
            .frame(
                width: LeafStatusPillTokens.dotSlotSize,
                height: LeafStatusPillTokens.dotSlotSize
            )
            Text(state.label)
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.secondary)
        }
        .padding(.horizontal, LeafStatusPillTokens.horizontalPadding)
        .padding(.vertical, LeafStatusPillTokens.verticalPadding)
        .background(Capsule().fill(LeafColor.surface.inset))
        .onAppear {
            guard state.pulses, !(systemReduce || debugReduce) else { return }
            withAnimation(
                .easeOut(duration: LeafStatusPillTokens.pulseDuration)
                    .repeatForever(autoreverses: false)
            ) {
                pulse = true
            }
        }
    }
}
