//
//  LeafBanner.swift
//  Track 2 / D1 — Organism O6. Inline notice surface — icon + title +
//  optional description + optional CTA + optional dismiss. 4 tones
//  (info / success / warning / danger). Used for non-modal alerts (rotation
//  banner, sharing-paused banner, update-ready banner).
//

import SwiftUI

struct LeafBanner: View {
    let tone: LeafBannerTokens.Tone
    let title: String
    var description: String? = nil
    var ctaTitle: String? = nil
    var onCTA: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: LeafSpace.md) {
            LeafIcon(asset: tone.icon, size: .md, tint: tone.border)
            VStack(alignment: .leading, spacing: LeafSpace.xs) {
                Text(title)
                    .font(LeafType.title.small)
                    .foregroundStyle(LeafColor.text.primary)
                if let description {
                    Text(description)
                        .font(LeafType.body.small)
                        .foregroundStyle(LeafColor.text.secondary)
                }
                if let ctaTitle, let onCTA {
                    LeafButton(ctaTitle, variant: .secondary, size: .sm, action: onCTA)
                        .padding(.top, LeafSpace.xs)
                }
            }
            Spacer()
            if let onDismiss {
                LeafIconButton(asset: LeafIcons.action.close, variant: .ghost, size: .sm, action: onDismiss)
            }
        }
        .padding(LeafBannerTokens.padding)
        .background(
            RoundedRectangle(cornerRadius: LeafBannerTokens.cornerRadius, style: .continuous)
                .fill(tone.bg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LeafBannerTokens.cornerRadius, style: .continuous)
                .strokeBorder(tone.border.opacity(LeafBannerTokens.borderOpacity), lineWidth: 1)
        )
    }
}
