//
//  LeafFeedRowPreview.swift
//  Track 5 / S7 B.4 — TokensPreview entry for LeafFeedRow.
//
//  Variants:
//  1. Git commit — single row (gitCommits source)
//  2. Linear issue update — single row (linearIssues source)
//  3. Slack mention — single row (slackMentions source)
//  4. GitHub PR — single row (githubPRs source)
//  5. Detected decision — single row (detectedDecisions source)
//  6. Detected blocker — single row (detectedBlockers source)
//  7. Grouped (gitCommits) — collapsed
//  8. Grouped (gitCommits) — expanded (3 children)
//

import SwiftUI
import LeafCore

#if DEBUG
struct LeafFeedRowPreview: View {

    // MARK: - State

    @State private var group1Expanded = false
    @State private var group2Expanded = true   // pre-expanded to show children

    // MARK: - Sample data

    private let now = Int64(Date().timeIntervalSince1970 * 1000)
    private func msAgo(minutes: Int) -> Int64 {
        now - Int64(minutes * 60 * 1000)
    }

    private let senderHex = String(repeating: "ab", count: 32)

    private func makeRow(
        eventID: String,
        source: ShareSource,
        kind: String,
        payload: [String: String],
        minutesAgo: Int
    ) -> TeamEventMirrorRow {
        let payloadJSON = (try? JSONSerialization.data(
            withJSONObject: payload,
            options: []
        )).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        return TeamEventMirrorRow(
            eventID: eventID,
            workspaceID: "ws-preview",
            senderPubkeyHex: senderHex,
            source: source,
            kind: kind,
            plaintextPayloadJSON: payloadJSON,
            serverCreatedAtMs: msAgo(minutes: minutesAgo),
            eventTsMs: msAgo(minutes: minutesAgo),
            receivedAtMs: now
        )
    }

    // Individual sample rows

    private var gitCommitRow: TeamEventMirrorRow {
        makeRow(
            eventID: "e-001",
            source: .gitCommits,
            kind: "git_commit",
            payload: ["title": "feat(theme): LeafFeedRow atoms + preview"],
            minutesAgo: 5
        )
    }

    private var linearIssueRow: TeamEventMirrorRow {
        makeRow(
            eventID: "e-002",
            source: .linearIssues,
            kind: "linear_status_transition",
            payload: ["title": "S7 TeamView feed atom", "to_state": "In Progress"],
            minutesAgo: 12
        )
    }

    private var slackMentionRow: TeamEventMirrorRow {
        makeRow(
            eventID: "e-003",
            source: .slackMentions,
            kind: "slack_mention",
            payload: [:],
            minutesAgo: 18
        )
    }

    private var githubPRRow: TeamEventMirrorRow {
        makeRow(
            eventID: "e-004",
            source: .githubPRs,
            kind: "pr_opened",
            payload: ["title": "feat(relay): slack_post real body"],
            minutesAgo: 35
        )
    }

    private var decisionRow: TeamEventMirrorRow {
        makeRow(
            eventID: "e-005",
            source: .detectedDecisions,
            kind: "decision",
            payload: ["reasoning_excerpt": "Forwarded-token pattern beats server-stored token for privacy"],
            minutesAgo: 60
        )
    }

    private var blockerRow: TeamEventMirrorRow {
        makeRow(
            eventID: "e-006",
            source: .detectedBlockers,
            kind: "blocker_pattern",
            payload: ["blocker_excerpt": "Deno install hangs in CI — blocks Deno unit test verification step"],
            minutesAgo: 90
        )
    }

    // Grouped children (3 git commits)

    private var groupedChildren: [TeamEventMirrorRow] {
        [
            makeRow(eventID: "g-001", source: .gitCommits, kind: "git_commit",
                    payload: ["title": "feat(theme): LeafFeedRowTokens"], minutesAgo: 8),
            makeRow(eventID: "g-002", source: .gitCommits, kind: "git_commit",
                    payload: ["title": "feat(theme): LeafFeedRow single + grouped"], minutesAgo: 6),
            makeRow(eventID: "g-003", source: .gitCommits, kind: "git_commit",
                    payload: ["title": "feat(theme): LeafFeedRowPreview 8 variants"], minutesAgo: 5),
        ]
    }

    // M-IX: precompute once for both grouped previews (DRY).
    private var renderedGroupedChildren: [RenderedTeamEvent] {
        groupedChildren.map(RenderedTeamEvent.init(row:))
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LeafSpace.lg) {
                Text("LeafFeedRow")
                    .font(LeafType.title.medium)
                    .foregroundStyle(LeafColor.text.primary)

                sectionLabel("1 · Git commit (gitCommits source)")
                LeafFeedRow(event: RenderedTeamEvent(row: gitCommitRow), attachmentMetadata: nil, onTap: {})

                sectionLabel("2 · Linear issue (linearIssues source)")
                LeafFeedRow(event: RenderedTeamEvent(row: linearIssueRow), attachmentMetadata: nil, onTap: {})

                sectionLabel("3 · Slack mention (slackMentions source)")
                LeafFeedRow(event: RenderedTeamEvent(row: slackMentionRow), attachmentMetadata: nil, onTap: {})

                sectionLabel("4 · GitHub PR (githubPRs source)")
                LeafFeedRow(event: RenderedTeamEvent(row: githubPRRow), attachmentMetadata: nil, onTap: {})

                sectionLabel("5 · Detected decision (detectedDecisions source)")
                LeafFeedRow(event: RenderedTeamEvent(row: decisionRow), attachmentMetadata: nil, onTap: {})

                sectionLabel("6 · Detected blocker (detectedBlockers source)")
                LeafFeedRow(event: RenderedTeamEvent(row: blockerRow), attachmentMetadata: nil, onTap: {})

                sectionLabel("7 · Grouped — collapsed (tap to expand)")
                LeafFeedRow.grouped(
                    source: .gitCommits,
                    senderDisplayName: "dima",
                    senderPubkeyHex: senderHex,
                    count: 3,
                    spanStartMs: msAgo(minutes: 10),
                    spanEndMs: msAgo(minutes: 4),
                    expandedItems: renderedGroupedChildren,
                    isExpanded: $group1Expanded
                )

                sectionLabel("8 · Grouped — pre-expanded (3 children indented)")
                LeafFeedRow.grouped(
                    source: .gitCommits,
                    senderDisplayName: "dima",
                    senderPubkeyHex: senderHex,
                    count: 3,
                    spanStartMs: msAgo(minutes: 10),
                    spanEndMs: msAgo(minutes: 4),
                    expandedItems: renderedGroupedChildren,
                    isExpanded: $group2Expanded
                )

                TokensInlineSpec(
                    spec: "LeafFeedRow · single + grouped · 8 variants",
                    codeSnippet: "LeafFeedRow(event:attachmentMetadata:onTap:) / LeafFeedRow.grouped(source:senderDisplayName:senderPubkeyHex:count:spanStartMs:spanEndMs:expandedItems:isExpanded:)"
                )
            }
            .padding(LeafSpace.lg)
        }
        .background(LeafColor.surface.canvas)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
        .frame(width: 560)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .leafSectionLabel()
            .foregroundStyle(LeafColor.text.tertiary)
    }
}

#Preview("LeafFeedRow") {
    LeafFeedRowPreview()
        .padding()
}
#endif
