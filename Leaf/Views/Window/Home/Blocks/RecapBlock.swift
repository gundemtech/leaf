//
//  RecapBlock.swift
//  Track-10 T8 — Zone-5 morning standup helper. Auto-expanded between
//  06:00 and 11:00 (hour bucket via `StandupComposer.isRecapExpanded`).
//  Header tap toggles regardless of hour; `@State` only — no
//  UserDefaults persistence (Brainstorm Q3 rejected).
//
//  Empty-state takes precedence over `hasCleanBreak` (F-CTO-T8-I).
//
//  Spec: docs/superpowers/specs/2026-05-23-track-10-T8-recap-eod.md §3.7
//

import LeafCore
import SwiftUI

struct RecapBlock: View {
    let snapshot: StandupRecap?
    @State private var expanded: Bool

    // Stage 6 fix-bundle — removed dead `@Environment(\.calendar)`; init
    // resolves hour via `Calendar.current` (env not accessible in init).

    init(snapshot: StandupRecap?, now: Date = Date()) {
        self.snapshot = snapshot
        let hour = Calendar.current.component(.hour, from: now)
        self._expanded = State(initialValue: StandupComposer.isRecapExpanded(atHour: hour))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.sm) {
            StandupHeaderRow(
                label: "RECAP",
                subtitle: "morning brief",
                expanded: expanded,
                onTap: { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } }
            )
            if expanded {
                LeafCard(padding: .regular) {
                    if let recap = snapshot, !recap.isEmpty {
                        RecapBody(recap: recap)
                    } else {
                        emptyState
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var emptyState: some View {
        LeafEmptyState(
            icon: LeafIcons.brand.leaf,
            title: "Nothing captured yesterday.",
            style: .compact
        )
    }
}

private struct RecapBody: View {
    let recap: StandupRecap

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.xs) {
            // Yesterday summary line: "Yesterday: 3 commits · closed
            // GUN-204, GUN-187 · reviewed 2 PRs". Composer drops empty
            // segments so a quiet day reads naturally.
            if let yesterday = yesterdaySummary {
                line(yesterday, prominent: true)
            }
            // "Today: continuing GUN-208" anchor — TaskIdentity reused
            // from Zone-4 YOU'RE ON (different temporal voice — F-CTO-T8-D).
            if let todayLine {
                line(todayLine, prominent: false)
            }
            ForEach(recap.waitingItems, id: \.id) { item in
                bullet(StandupComposer.renderWaitingBullet(item, now: Date()))
            }
            ForEach(recap.openBlockers, id: \.id) { blocker in
                bullet(StandupComposer.renderBlockerBullet(blocker))
            }
        }
    }

    private var yesterdaySummary: String? {
        var segments: [String] = []
        if recap.yesterdayCommitsCount > 0 {
            let unit = recap.yesterdayCommitsCount == 1 ? "commit" : "commits"
            segments.append("\(recap.yesterdayCommitsCount) \(unit)")
        }
        if let clause = StandupComposer.renderLinearKeysClause(recap.yesterdayClosedLinearKeys) {
            segments.append(clause)
        }
        if recap.yesterdayReviewedPRsCount > 0 {
            let unit = recap.yesterdayReviewedPRsCount == 1 ? "PR" : "PRs"
            segments.append("reviewed \(recap.yesterdayReviewedPRsCount) \(unit)")
        }
        guard !segments.isEmpty else { return nil }
        return "Yesterday: " + segments.joined(separator: " · ")
    }

    private var todayLine: String? {
        guard let task = recap.todayContinuing,
              let id = task.linearID, !id.isEmpty else { return nil }
        return "Today: continuing \(id)"
    }

    @ViewBuilder
    private func line(_ text: String, prominent: Bool) -> some View {
        Text(text)
            .font(LeafType.body.small)
            .foregroundStyle(prominent ? LeafColor.text.primary : LeafColor.text.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: LeafSpace.xs) {
            Text("•")
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.tertiary)
            Text(text)
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
