//
//  LeafLinkedEventCardPreview.swift
//  Track 5 / S7 B.7 — TokensPreview entry for LeafLinkedEventCard.
//
//  Shows:
//  - Full variant: all 3 providers × loaded state × 4 status colours
//  - Full variant: loading state (nil metadata)
//  - Compact variant: all 3 providers
//

import SwiftUI
import LeafCore

#if DEBUG
struct LeafLinkedEventCardPreview: View {

    private let githubURL = URL(string: "https://github.com/gundemtech/leaf/pull/42")!
    private let linearURL = URL(string: "https://linear.app/gundem/issue/LEA-42")!
    private let slackURL  = URL(string: "https://slack.com/archives/C123/p456")!

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.lg) {
            Text("LeafLinkedEventCard")
                .font(LeafType.title.medium)
                .foregroundStyle(LeafColor.text.primary)

            // Full — loaded states, 3 providers
            Text("Full · Loaded")
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.tertiary)
                .leafSectionLabel()

            fullLoadedSection

            // Full — loading (nil metadata)
            Text("Full · Loading")
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.tertiary)
                .leafSectionLabel()

            fullLoadingSection

            // Compact — 3 providers
            Text("Compact")
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.tertiary)
                .leafSectionLabel()

            compactSection

            TokensInlineSpec(
                spec: "LeafLinkedEventCard · full/compact · github/linear/slack · loaded/loading",
                codeSnippet: "LeafLinkedEventCard(metadata: meta, externalRef: \"LEA-42\", provider: .linear, style: .full) { … }"
            )
        }
        .padding(LeafSpace.lg)
        .background(LeafColor.surface.canvas)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
    }

    // MARK: - Sections

    @ViewBuilder
    private var fullLoadedSection: some View {
        VStack(spacing: LeafSpace.sm) {
            LeafLinkedEventCard(
                metadata: .init(
                    title: "feat(theme): LeafLinkedEventCard + value types",
                    statusLabel: "open",
                    statusColorKey: .open,
                    authorDisplayName: "anton",
                    createdAtMs: msAgo(minutes: 12),
                    externalURL: githubURL
                ),
                externalRef: "#42",
                provider: .github,
                style: .full,
                onTap: {}
            )
            LeafLinkedEventCard(
                metadata: .init(
                    title: "feat(theme): LeafLinkedEventCard merged",
                    statusLabel: "merged",
                    statusColorKey: .merged,
                    authorDisplayName: "dima",
                    createdAtMs: msAgo(minutes: 60),
                    externalURL: githubURL
                ),
                externalRef: "#38",
                provider: .github,
                style: .full,
                onTap: {}
            )
            LeafLinkedEventCard(
                metadata: .init(
                    title: "Track 5 / S7 — Team UI atoms",
                    statusLabel: "In Progress",
                    statusColorKey: .inProgress,
                    authorDisplayName: "anton",
                    createdAtMs: msAgo(minutes: 90),
                    externalURL: linearURL
                ),
                externalRef: "LEA-42",
                provider: .linear,
                style: .full,
                onTap: {}
            )
            LeafLinkedEventCard(
                metadata: .init(
                    title: "Track 5 / S7 — blocked on relay deploy",
                    statusLabel: "Blocked",
                    statusColorKey: .blocked,
                    authorDisplayName: "dima",
                    createdAtMs: msAgo(minutes: 180),
                    externalURL: linearURL
                ),
                externalRef: "LEA-39",
                provider: .linear,
                style: .full,
                onTap: {}
            )
            LeafLinkedEventCard(
                metadata: .init(
                    title: "Team UI cross-post discussion",
                    statusLabel: nil,
                    statusColorKey: .neutral,
                    authorDisplayName: "anton",
                    createdAtMs: msAgo(minutes: 5),
                    externalURL: slackURL
                ),
                externalRef: "#leaf-architecture",
                provider: .slack,
                style: .full,
                onTap: {}
            )
        }
    }

    @ViewBuilder
    private var fullLoadingSection: some View {
        VStack(spacing: LeafSpace.sm) {
            LeafLinkedEventCard(
                metadata: nil,
                externalRef: "#44",
                provider: .github,
                style: .full,
                onTap: {}
            )
            LeafLinkedEventCard(
                metadata: nil,
                externalRef: "LEA-55",
                provider: .linear,
                style: .full,
                onTap: {}
            )
            LeafLinkedEventCard(
                metadata: nil,
                externalRef: "#eng-general",
                provider: .slack,
                style: .full,
                onTap: {}
            )
        }
    }

    @ViewBuilder
    private var compactSection: some View {
        VStack(alignment: .leading, spacing: LeafSpace.xs) {
            LeafLinkedEventCard(
                metadata: nil,
                externalRef: "#42",
                provider: .github,
                style: .compact,
                onTap: {}
            )
            LeafLinkedEventCard(
                metadata: nil,
                externalRef: "LEA-42",
                provider: .linear,
                style: .compact,
                onTap: {}
            )
            LeafLinkedEventCard(
                metadata: nil,
                externalRef: "#leaf-architecture",
                provider: .slack,
                style: .compact,
                onTap: {}
            )
        }
        .padding(LeafSpace.sm)
        .background(
            RoundedRectangle(cornerRadius: LeafRadius.md, style: .continuous)
                .fill(LeafColor.surface.raised)
        )
    }

    // MARK: - Helpers

    private func msAgo(minutes: Int) -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000) - Int64(minutes * 60 * 1000)
    }
}
#endif
