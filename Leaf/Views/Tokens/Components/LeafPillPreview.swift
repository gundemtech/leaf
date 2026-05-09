//
//  LeafPillPreview.swift
//  Track 2 / D1 — TokensPreview entry for Molecule M3 LeafPill.
//

import SwiftUI

#if DEBUG
struct LeafPillPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("LeafPill").font(LeafType.title.medium).foregroundStyle(LeafColor.text.primary)

            VStack(alignment: .leading, spacing: LeafSpace.sm) {
                Text("plain")
                    .font(LeafType.mono.small)
                    .foregroundStyle(LeafColor.text.tertiary)
                HStack(spacing: LeafSpace.sm) {
                    LeafPill(title: "neutral", tone: .neutral)
                    LeafPill(title: "accent",  tone: .accent)
                    LeafPill(title: "success", tone: .success)
                    LeafPill(title: "warning", tone: .warning)
                    LeafPill(title: "danger",  tone: .danger)
                }

                Text("with leading dot")
                    .font(LeafType.mono.small)
                    .foregroundStyle(LeafColor.text.tertiary)
                HStack(spacing: LeafSpace.sm) {
                    LeafPill(title: "online",      tone: .success, showsDot: true)
                    LeafPill(title: "in meeting",  tone: .warning, showsDot: true)
                    LeafPill(title: "deep focus",  tone: .accent,  showsDot: true)
                    LeafPill(title: "offline",     tone: .neutral, showsDot: true)
                }

                Text("with icon")
                    .font(LeafType.mono.small)
                    .foregroundStyle(LeafColor.text.tertiary)
                HStack(spacing: LeafSpace.sm) {
                    LeafPill(title: "GitHub", tone: .neutral, icon: "chevron.left.forwardslash.chevron.right")
                    LeafPill(title: "Linear", tone: .accent,  icon: "circle.dotted")
                    LeafPill(title: "Slack",  tone: .success, icon: "bubble.left.and.bubble.right")
                }
            }

            TokensInlineSpec(
                spec: "LeafPill · 5 tones · optional dot/icon · LeafType.body.small · Capsule",
                codeSnippet: "LeafPill(title: \"online\", tone: .success, showsDot: true)"
            )
        }
        .padding(LeafSpace.lg)
        .background(LeafColor.surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
    }
}
#endif
