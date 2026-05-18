//
//  WorkStateCard.swift
//  Track 7 P3 — Home card render for the always-on D3 Work State surface
//  (master spec §6.1). Standalone composite (does NOT reuse SurfaceCard —
//  Work State is not a HomeSurface and has no Spark slot).
//
//  Layout: HStack { LeafIcon · VStack{headline · subLine} · Spacer · chevron }.
//  Wrapped in LeafCard(.raised) inside a Button so the entire card is the
//  tap target. Sub-line is conditionally greyed when stale (last decision
//  older than 7 days).
//

import LeafCore
import SwiftUI

struct WorkStateCard: View {
    let headline: String
    let subLineExcerpt: String?
    let subLineIsStale: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            LeafCard(variant: .raised, padding: .regular) {
                HStack(alignment: .center, spacing: LeafSpace.md) {
                    LeafIcon(
                        systemName: "checkmark.bubble.fill",
                        size: .lg,
                        tint: LeafColor.accent.primary)
                    VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                        Text(headline)
                            .font(LeafType.title.medium)
                            .foregroundStyle(LeafColor.text.primary)
                        if let sub = subLineExcerpt, !sub.isEmpty {
                            Text(sub)
                                .font(LeafType.body.regular)
                                .foregroundStyle(
                                    subLineIsStale
                                        ? LeafColor.text.tertiary
                                        : LeafColor.text.secondary
                                )
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    Spacer(minLength: LeafSpace.md)
                    LeafIcon(
                        systemName: "chevron.right",
                        size: .sm,
                        tint: LeafColor.text.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityLabel: String {
        if let sub = subLineExcerpt, !sub.isEmpty {
            return "Work State: \(headline). \(sub)"
        } else {
            return "Work State: \(headline)"
        }
    }
}
