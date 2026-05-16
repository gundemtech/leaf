//
//  CrossPostPrivacyBanner.swift
//  Leaf
//
//  Track 5 / S6 T12 — 🔓 privacy banner shown in SendDirectMessageSheet
//  whenever a non-Leaf cross-post toggle (Slack / Linear) is ON.
//
//  Per spec §6 trust invariant — DM body that flows to Slack/Linear leaves
//  Leaf's encrypted channel. Workspace admins and Linear API can read it,
//  and anyone with channel/issue access can see it. This banner makes
//  that intent explicit BEFORE the user hits Send — NOT a tooltip, not a
//  disclosure, not a one-time consent. It stays visible the entire time
//  any non-Leaf toggle is on, per Track 5 contract §10.
//
//  Visual:
//   - LeafCard.raised wrapped, warning-tinted icon chip + title + body.
//   - LeafColor.status.warning for icon tint + amber-ish border accent.
//   - 🔓 emoji used directly in the title row (matches spec §9.1
//     wireframe — lock-open icon, not the Asset Catalog warning glyph,
//     so the visual reads as "encryption opened" specifically rather
//     than the generic ⚠ used elsewhere).
//   - Non-dismissable. User controls visibility via toggle state.
//

import SwiftUI

struct CrossPostPrivacyBanner: View {
    var body: some View {
        LeafCard(variant: .raised, padding: .regular) {
            HStack(alignment: .top, spacing: LeafSpace.md) {
                Image(systemName: "lock.open.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(LeafColor.status.warning)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                    Text("Posting outside Leaf's encrypted channel")
                        .font(LeafType.body.regular)
                        .foregroundStyle(LeafColor.text.primary)
                    Text(
                        "Slack workspace admins and Linear API can read this message. " +
                        "Anyone with channel or issue access can see it."
                    )
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        // Warning hairline overlay — reinforces tone without re-skinning the
        // entire card surface. LeafCard already strokes border.subtle; this
        // overlay swaps in status.warning at 60% opacity for the cross-post
        // case (intent: clearly different from neutral cards).
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(LeafColor.status.warning.opacity(0.6), lineWidth: 1)
        )
    }
}
