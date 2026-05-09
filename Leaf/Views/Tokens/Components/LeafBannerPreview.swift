//
//  LeafBannerPreview.swift
//  Track 2 / D1 — TokensPreview entry for Organism O6 LeafBanner.
//

import SwiftUI

#if DEBUG
struct LeafBannerPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("LeafBanner")
                .font(LeafType.title.medium)
                .foregroundStyle(LeafColor.text.primary)

            VStack(alignment: .leading, spacing: LeafSpace.md) {
                LeafBanner(
                    tone: .info,
                    title: "New version available",
                    description: "Leaf 0.2.0 is ready to install.",
                    ctaTitle: "Install now",
                    onCTA: {}
                )
                LeafBanner(
                    tone: .success,
                    title: "Linear connected",
                    description: "Activity sync started — first events arrive shortly."
                )
                LeafBanner(
                    tone: .warning,
                    title: "Sharing paused",
                    description: "Reconnect a relay to resume team presence.",
                    ctaTitle: "Reconnect",
                    onCTA: {},
                    onDismiss: {}
                )
                LeafBanner(
                    tone: .danger,
                    title: "Removed from Acme team",
                    description: "Your local data stays — relay access is revoked.",
                    onDismiss: {}
                )
            }

            TokensInlineSpec(
                spec: "LeafBanner · info/success/warning/danger · icon + title + desc + optional CTA + optional dismiss",
                codeSnippet: "LeafBanner(tone: .info, title: \"…\", description: \"…\")"
            )
        }
        .padding(LeafSpace.lg)
        .background(LeafColor.surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
    }
}
#endif
