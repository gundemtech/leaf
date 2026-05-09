//
//  LeafPill.swift
//  Track 2 / D1 — Molecule M3. Compact pill chip with optional leading dot
//  and/or icon. Tones via LeafPillTokens.Tone.
//

import SwiftUI

struct LeafPill: View {
    let title: String
    var tone: LeafPillTokens.Tone = .neutral
    var icon: String? = nil
    var showsDot: Bool = false

    var body: some View {
        HStack(spacing: LeafSpace.xs) {
            if showsDot { LeafDot(tone: tone.dotTone, size: .sm) }
            if let icon {
                Image(systemName: icon).font(.system(size: 11))
            }
            Text(title).font(LeafType.body.small)
        }
        .foregroundStyle(tone.fg)
        .padding(.horizontal, LeafSpace.sm)
        .padding(.vertical, LeafSpace.xxs)
        .background(Capsule().fill(tone.bg))
    }
}
