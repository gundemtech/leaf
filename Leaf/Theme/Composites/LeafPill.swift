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
            // 11pt — matches body.small text (13pt) leaving a hair of
            // breathing room. SF compensation factor not needed at this
            // small size — already balanced with text.
            Image(name)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 11, height: 11)
        case .none:
            EmptyView()
        }
    }
}
