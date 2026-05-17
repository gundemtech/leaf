//
//  SurfaceCardCompact.swift
//  Track 7 P2-collapsed polish — compact card for enabled-but-no-data states
//  (`.enabledZeroToday` / `.enabledEmpty`). Single-line, ~48pt tall, entire
//  row tappable. Visually distinct from `SurfaceRow` (disabled, 36pt, dimmed
//  icon, "Off" pill + "Enable" CTA) and from `SurfaceCard` (populated, large,
//  multi-line, sparkline). Removes the "Open for details / Daily activity in
//  the detail screen" placeholder copy that read as visual noise across 5
//  identical empty cards.
//
//  Promotes to `SurfaceCard` once `<surface>Activity` is non-nil on the
//  snapshot (Phase E SQL helpers land downstream).
//

import SwiftUI
import LeafCore

struct SurfaceCardCompact: View {
    let surface: HomeSurface
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: LeafSpace.md) {
                LeafIcon(surface: surface)
                Text(surface.displayName)
                    .font(LeafType.body.regular)
                    .foregroundStyle(LeafColor.text.primary)
                Spacer()
                LeafIcon(systemName: "chevron.right",
                         size: .sm,
                         tint: LeafColor.text.tertiary)
            }
            .padding(.horizontal, LeafSpace.lg)
            .frame(height: LeafSpace.xxxl)
            .background(LeafColor.surface.raised)
            .clipShape(RoundedRectangle(cornerRadius: LeafCardTokens.cornerRadius,
                                        style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(surface.displayName), open for details")
        .accessibilityAddTraits(.isButton)
    }
}
