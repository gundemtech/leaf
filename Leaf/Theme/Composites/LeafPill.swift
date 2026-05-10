//
//  LeafPill.swift
//  Track 2 / D1 — Molecule M3. Compact pill chip with optional leading dot
//  and/or icon (SF Symbol or Asset Catalog). Tones via LeafPillTokens.Tone.
//

import SwiftUI

struct LeafPill: View {
    enum IconRef {
        case system(String)
        case asset(String)
    }

    let title: String
    var tone: LeafPillTokens.Tone = .neutral
    var icon: IconRef? = nil
    var showsDot: Bool = false

    var body: some View {
        HStack(spacing: LeafSpace.xs) {
            if showsDot { LeafDot(tone: tone.dotTone, size: .sm) }
            iconView
            Text(title).font(LeafType.body.small)
        }
        .foregroundStyle(tone.fg)
        .padding(.horizontal, LeafSpace.sm)
        .padding(.vertical, LeafSpace.xxs)
        .background(Capsule().fill(tone.bg))
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .system(let name):
            Image(systemName: name).font(.system(size: 11))
        case .asset(let name):
            // 0.85 compensation — asset SVG glyphs fill more of their bbox
            // than SF Symbols, so frame is reduced to match visual weight.
            Image(name)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 11 * 0.85, height: 11 * 0.85)
        case .none:
            EmptyView()
        }
    }
}
