//
//  WithYouOnThisBlock.swift
//  Track-8 / Phase 8.5 — Home WITH YOU ON THIS dashboard cell. Renders
//  up to 5 teammate rows surfaced by
//  `DerivedInsights.sameTaskTeammates(rule: .hierarchical)`. Substrate
//  (Phase 8.1 `SameTaskMatcher`) resolves rule + sort: confidence asc →
//  lastActivityAtMs desc → displayName asc. Returns [] until Phase 5.4
//  wires DBTeammatePresenceReader against `presence_history`, so this
//  block typically renders the empty state in production today.
//
//  Master spec §4.3: 5-row cap, "+N more" overflow, empty state with
//  Team CTA. Offline footer + "N active elsewhere" count are P5 carry
//  to §9.1 (C-10, C-11) — pending Phase 5.4 / 5.6 substrate.
//

import LeafCore
import SwiftUI

struct WithYouOnThisBlock: View {
    let matches: [TeammateMatch]

    @Environment(WindowState.self) private var windowState

    private static let rowCap = 5

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("WITH YOU ON THIS")
                .leafSectionLabel()
                .foregroundStyle(LeafColor.text.tertiary)

            LeafCard(padding: .regular) {
                if matches.isEmpty {
                    emptyState
                } else {
                    Text("rows placeholder — Task 4")
                        .font(LeafType.body.regular)
                        .foregroundStyle(LeafColor.text.secondary)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: matches)
    }

    @ViewBuilder
    private var emptyState: some View {
        LeafEmptyState(
            icon: LeafIcons.brand.leaf,
            title: "No one's on this task right now.",
            description:
                "Teammates working on the same Linear issue, branch, or adjacent branch will appear here.",
            ctaTitle: "→ Team",
            onCTA: { windowState.section = .team }
        )
    }
}
