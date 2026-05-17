//
//  SurfaceRow.swift
//  Track 7 P1 — compact disabled-state row (spec §4.2). Single-line.
//  Row body itself is NOT tappable — only the trailing LeafButton triggers
//  the action (matches spec §4.2 accessibility contract). This avoids
//  ambiguity with adjacent enabled cards which ARE tappable.
//

import SwiftUI
import LeafCore

enum SurfaceRowAction {
    case enable    // toggles a UserDefaults preference
    case connect   // initiates an OAuth flow
}

struct SurfaceRow: View {
    let surface: HomeSurface
    let action: SurfaceRowAction
    let onTap: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: LeafSpace.md) {
            LeafIcon(systemName: surfaceSymbolName,
                     size: .md,
                     tint: LeafColor.text.tertiary)
            Text(surface.displayName)
                .font(LeafType.body.regular)
                .foregroundStyle(LeafColor.text.primary)
            Spacer()
            LeafPill(title: "Off", tone: .neutral)
            LeafButton(buttonTitle, variant: .secondary, size: .sm, action: onTap)
        }
        .padding(.horizontal, LeafSpace.lg)
        .frame(height: LeafSpace.xxl + LeafSpace.xs)   // 32 + 4 = 36pt
        .background(LeafColor.surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: LeafCardTokens.cornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(surface.displayName), capture is off, double tap to enable")
    }

    private var buttonTitle: String {
        switch action {
        case .enable:  "Enable"
        case .connect: "Connect"
        }
    }

    /// Mirrors `LeafIcon(surface:)` symbol mapping from SurfaceCard.swift but
    /// rendered at `.md` size with `text.tertiary` tint to read as "dimmed/off".
    /// We re-resolve the symbol name locally rather than calling `LeafIcon(surface:)`
    /// because that initializer hardcodes `.lg` + `accent.primary` for the enabled
    /// card aesthetic.
    private var surfaceSymbolName: String {
        switch surface {
        case .claudeCode: "sparkles"
        case .xcode:      "hammer.fill"
        case .ides:       "curlybraces.square"
        case .browsers:   "globe"
        case .zoom:       "video.fill"
        case .calendar:   "calendar"
        }
    }
}
