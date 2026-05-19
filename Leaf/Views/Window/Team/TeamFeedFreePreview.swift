//
//  TeamFeedFreePreview.swift
//  Track 5 / S8 / T4 — mockup feed for Free-tier users.
//
//  Renders a sticky CTA card at the top + 3 dimmed/dashed-border preview cards
//  showing what the Team feed looks like once the user upgrades. Used as the
//  `Group { if !tierGate.canSendDM { TeamFeedFreePreview(...) } else { ... } }`
//  branch in TeamView (T4 step 6).
//
//  Default tier in MVP = `.team` per `TierGate.defaultTier` so this view is
//  only reachable via dev/QA `defaults write tech.gundem.leaf tier free`. The
//  G22 acceptance smoke covers the visual + Upgrade CTA path.
//
//  Per spec §3.1 + contract §15.2 acceptance criterion:
//   1. Sticky CTA card (sender icon + headline + body + [Upgrade to Team] button).
//   2. Three mockup cards at 55% opacity with dashed borders — distinct visual
//      treatment so user perceives them as preview placeholders, not real data.
//

import SwiftUI
import LeafCore

struct TeamFeedFreePreview: View {
    let onUpgrade: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: LeafSpace.xl) {
                stickyCTA
                mockupSection
            }
            .padding(LeafSpace.xl)
        }
    }

    // MARK: - Sticky CTA card

    @ViewBuilder
    private var stickyCTA: some View {
        LeafCard(variant: .raised, padding: .generous) {
            VStack(spacing: LeafSpace.md) {
                Image(systemName: "person.3.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(LeafColor.accent.primary)
                Text("Team activity, encrypted end-to-end")
                    .font(LeafType.title.medium)
                    .foregroundStyle(LeafColor.text.primary)
                    .multilineTextAlignment(.center)
                Text("Upgrade to Leaf Team to send messages, share auto-detected decisions, and see your teammates' activity feed.")
                    .font(LeafType.body.regular)
                    .foregroundStyle(LeafColor.text.secondary)
                    .multilineTextAlignment(.center)
                LeafButton(
                    "Upgrade to Team — $30/seat",
                    variant: .primary,
                    size: .md,
                    action: onUpgrade
                )
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Mockup cards

    @ViewBuilder
    private var mockupSection: some View {
        VStack(spacing: LeafSpace.md) {
            ForEach(Self.mockupCards, id: \.id) { card in
                mockupRow(card)
            }
        }
    }

    @ViewBuilder
    private func mockupRow(_ card: MockCard) -> some View {
        HStack(alignment: .top, spacing: LeafSpace.md) {
            Image(systemName: card.icon)
                .font(.system(size: 18))
                .foregroundStyle(card.tint)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: LeafSpace.xs) {
                HStack(spacing: LeafSpace.sm) {
                    Text(card.sender)
                        .font(LeafType.body.regular)
                        .fontWeight(.semibold)
                        .foregroundStyle(LeafColor.text.primary)
                    Spacer()
                    Text(card.timestamp)
                        .font(LeafType.caption)
                        .foregroundStyle(LeafColor.text.tertiary)
                }
                Text(card.body)
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.secondary)
                    .lineLimit(2)
            }
        }
        .padding(LeafSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LeafColor.surface.canvas)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: LeafRadius.md, style: .continuous)
                .strokeBorder(
                    LeafColor.text.tertiary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
        )
        .opacity(0.55)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(card.sender) — \(card.body) (preview, requires Leaf Team)")
    }

    // MARK: - Mockup data

    private struct MockCard {
        let id: String
        let icon: String
        let sender: String
        let body: String
        let timestamp: String
        let tint: Color
    }

    /// Three sample cards — Handoff, Task, Decision. Chosen to advertise the
    /// three S6 cross-post kinds + auto-detected decision feed.
    private static let mockupCards: [MockCard] = [
        MockCard(
            id: "handoff-sample",
            icon: "arrow.right.circle.fill",
            sender: "Anna",
            body: "Handoff — finished OAuth flow, ready for review on PR #142",
            timestamp: "12 min ago",
            tint: LeafColor.accent.primary
        ),
        MockCard(
            id: "task-sample",
            icon: "checkmark.circle",
            sender: "Mark",
            body: "Task — wire SSH keys in onboarding",
            timestamp: "1 hr ago",
            tint: LeafColor.status.success
        ),
        MockCard(
            id: "decision-sample",
            icon: "lightbulb.fill",
            sender: "Decision",
            body: "Use S3 for blob storage (instead of R2 — lower egress costs)",
            timestamp: "3 hr ago",
            tint: LeafColor.status.warning
        ),
    ]
}
