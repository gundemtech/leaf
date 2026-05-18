//
//  SurfaceCard.swift
//  Track 7 P1 — full-card render for an enabled Home surface (spec §4.1).
//  Layout: HStack { icon · {headline + sub-stats} · spark · chevron }.
//  Wrapped in a button so the entire card is the tap target (cf. spec §4.1
//  "tap target = entire row"). Liquid Glass not used by design (spec §4.1).
//
//  Spark slot is generic so callers can supply LeafSparkline, Swift Charts
//  Chart, or a SwiftUI-rendered glyph without losing type-erasure.
//

import LeafCore
import SwiftUI

struct SurfaceCard<Spark: View>: View {
    let surface: HomeSurface
    let headline: String
    let subStats: [String]
    @ViewBuilder let spark: () -> Spark
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            LeafCard(variant: .raised, padding: .regular) {
                HStack(alignment: .center, spacing: LeafSpace.md) {
                    LeafIcon(surface: surface)
                    VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                        Text(headline)
                            .font(LeafType.title.medium)
                            .foregroundStyle(LeafColor.text.primary)
                        if !subStats.isEmpty {
                            Text(subStats.joined(separator: " · "))
                                .font(LeafType.body.regular)
                                .foregroundStyle(LeafColor.text.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    Spacer(minLength: LeafSpace.md)
                    spark()
                        .frame(
                            width: LeafSpace.xxxl + LeafSpace.xxl,  // 80pt
                            height: LeafSpace.xxl - LeafSpace.xs)  // 28pt
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
        let stats = subStats.joined(separator: ", ")
        return stats.isEmpty
            ? "\(surface.displayName): \(headline)"
            : "\(surface.displayName): \(headline), \(stats)"
    }
}

// MARK: - LeafIcon convenience initializer for HomeSurface

/// Resolves SF Symbol for a Home surface. Centralized here so surface ↔ glyph
/// mapping lives next to the card render. Picks SF Symbols rather than asset
/// catalog entries to avoid shipping new assets in P1.
extension LeafIcon {
    init(surface: HomeSurface) {
        let symbol: String =
            switch surface {
            case .claudeCode: "sparkles"
            case .xcode: "hammer.fill"
            case .ides: "curlybraces.square"
            case .browsers: "globe"
            case .zoom: "video.fill"
            case .calendar: "calendar"
            }
        self.init(systemName: symbol, size: .lg, tint: LeafColor.accent.primary)
    }
}
