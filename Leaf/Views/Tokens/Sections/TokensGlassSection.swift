//
//  TokensGlassSection.swift
//  Track 2 / D1 — Preview tiles for LeafGlass.* with macOS 26 / 14 fallback story.
//

import SwiftUI

#if DEBUG
struct TokensGlassSection: View {
    @Binding var forceLegacy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.lg) {
            HStack {
                Text("Glass").font(LeafType.title.large).foregroundStyle(LeafColor.text.primary)
                Spacer()
                Toggle("Force fallback (preview macOS 14 path)", isOn: $forceLegacy)
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.secondary)
            }
            HStack(spacing: LeafSpace.lg) {
                tile("thin",         .thin)
                tile("regular",      .regular)
                tile("thick",        .thick)
                tile("accentTinted", .accentTinted)
            }
            Text(versionBanner).font(LeafType.mono.small).foregroundStyle(LeafColor.text.tertiary)
        }
        .environment(\.forceLegacyGlass, forceLegacy)
    }

    private var versionBanner: String {
        if #available(macOS 26, *) {
            return forceLegacy ? "macOS 26 — forced fallback render" : "macOS 26 — Liquid Glass active"
        } else {
            return "macOS 14/15 — Material fallback render"
        }
    }

    private func tile(_ name: String, _ variant: LeafGlass) -> some View {
        VStack(spacing: LeafSpace.sm) {
            ZStack {
                LinearGradient(colors: [LeafColor.accent.primary, LeafColor.status.info],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
                Text("Glass").font(LeafType.title.medium).foregroundStyle(LeafColor.text.inverse)
            }
            .frame(width: 160, height: 100)
            .leafGlass(variant, cornerRadius: LeafRadius.lg)
            Text(name).font(LeafType.mono.small).foregroundStyle(LeafColor.text.tertiary)
        }
    }
}
#endif
