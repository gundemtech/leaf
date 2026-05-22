//
//  LeafBanner.swift
//  Track 2 / D1 — Organism O6. Inline notice surface. Neutral raised surface
//  with a tone-tinted leading LeafIconChip + hairline border in
//  LeafColor.border.subtle. 4 tones (info / success / warning / danger).
//  Used for non-modal alerts (rotation banner, sharing-paused banner,
//  update-ready banner).
//
//  Layout:
//      ┌─ LeafSpace.lg padding ─────────────────────────────────┐
//      │  ▣  title                                          ✕   │  ← chip + title row + dismiss
//      │     description                                        │
//      │     [ CTA ]                                            │  ← optional, separated by sm gap
//      └────────────────────────────────────────────────────────┘
//

import SwiftUI

struct LeafBanner: View {
  /// Type-scale variant. `.regular` keeps the 17pt semibold title used by
  /// rotation / sharing-paused / update-ready banners; `.compact` shrinks the
  /// title to 13pt regular for inline-validation surfaces (e.g. invite-code
  /// paste error inside JoinWorkspaceByCodeSheet) where a 17pt banner reads
  /// as a heavy modal interruption next to the surrounding small text.
  enum Density {
    case regular
    case compact
  }

  let tone: LeafBannerTokens.Tone
  let title: String
  var description: String? = nil
  var ctaTitle: String? = nil
  var onCTA: (() -> Void)? = nil
  var onDismiss: (() -> Void)? = nil
  var density: Density = .regular

  var body: some View {
    HStack(alignment: .top, spacing: LeafSpace.md) {
      LeafIconChip(asset: tone.icon, size: LeafBannerTokens.chipSize, tint: tone.tint)

      VStack(alignment: .leading, spacing: LeafBannerTokens.titleDescriptionGap) {
        Text(title)
          .font(density == .compact ? LeafType.body.small : LeafType.title.small)
          .foregroundStyle(LeafColor.text.primary)
          .fixedSize(horizontal: false, vertical: true)
        if let description {
          Text(description)
            .font(LeafType.body.small)
            .foregroundStyle(LeafColor.text.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let ctaTitle, let onCTA {
          LeafButton(ctaTitle, variant: .primary, size: .sm, action: onCTA)
            .padding(.top, LeafBannerTokens.bodyCTAGap)
        }
      }

      Spacer(minLength: 0)

      if let onDismiss {
        LeafIconButton(asset: LeafIcons.action.close, variant: .ghost, size: .md, action: onDismiss)
      }
    }
    .padding(LeafBannerTokens.padding)
    .background(
      RoundedRectangle(cornerRadius: LeafBannerTokens.cornerRadius, style: .continuous)
        .fill(LeafColor.surface.raised)
    )
    .overlay(
      RoundedRectangle(cornerRadius: LeafBannerTokens.cornerRadius, style: .continuous)
        .strokeBorder(LeafColor.border.subtle, lineWidth: 1)
    )
  }
}
