//
//  EodBlock.swift
//  Track-10 T8 — Zone-5 end-of-day standup helper. Auto-expanded between
//  17:00 and 23:00 (hour bucket via `StandupComposer.isEodExpanded`).
//  Header tap toggles regardless of hour; `@State` only — no
//  UserDefaults persistence (Brainstorm Q3 rejected).
//
//  Empty-state takes precedence over `hasCleanBreak` (F-CTO-T8-I).
//
//  Spec: docs/superpowers/specs/2026-05-23-track-10-T8-recap-eod.md §3.7
//

import LeafCore
import SwiftUI

struct EodBlock: View {
    let snapshot: StandupEod?
    @State private var expanded: Bool

    // Stage 6 fix-bundle — removed dead `@Environment(\.calendar)`; init
    // resolves hour via `Calendar.current` (env not accessible in init).

    init(snapshot: StandupEod?, now: Date = Date()) {
        self.snapshot = snapshot
        let hour = Calendar.current.component(.hour, from: now)
        self._expanded = State(initialValue: StandupComposer.isEodExpanded(atHour: hour))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.sm) {
            StandupHeaderRow(
                label: "EOD",
                subtitle: "end-of-day",
                expanded: expanded,
                onTap: { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } }
            )
            if expanded {
                LeafCard(padding: .regular) {
                    if let eod = snapshot, !eod.isEmpty {
                        EodBody(eod: eod)
                    } else {
                        emptyState
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        Text("Nothing captured today yet.")
            .font(LeafType.body.small)
            .foregroundStyle(LeafColor.text.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EodBody: View {
    let eod: StandupEod

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.xs) {
            if let todayLine {
                line(todayLine, prominent: true)
            }
            if let tomorrow = tomorrowLine {
                line(tomorrow, prominent: false)
            }
            if eod.hasCleanBreak && !carryHasContent {
                line("Clean break: nothing critical hanging.", prominent: false)
            }
            ForEach(eod.carryWaitingItems, id: \.id) { item in
                bullet(StandupComposer.renderWaitingBullet(item, now: Date()))
            }
            ForEach(eod.carryOpenBlockers, id: \.id) { blocker in
                bullet(StandupComposer.renderBlockerBullet(blocker))
            }
        }
    }

    /// "Today: 5 commits · closed GUN-300 · reviewed 1 PR" — composer drops
    /// empty segments. Returns nil when all three contribute nothing
    /// (caller skips the line).
    private var todayLine: String? {
        var segments: [String] = []
        if eod.todayCommitsCount > 0 {
            let unit = eod.todayCommitsCount == 1 ? "commit" : "commits"
            segments.append("\(eod.todayCommitsCount) \(unit)")
        }
        if let clause = StandupComposer.renderLinearKeysClause(eod.todayClosedLinearKeys) {
            segments.append(clause)
        }
        if eod.todayReviewedPRsCount > 0 {
            let unit = eod.todayReviewedPRsCount == 1 ? "PR" : "PRs"
            segments.append("reviewed \(eod.todayReviewedPRsCount) \(unit)")
        }
        guard !segments.isEmpty else { return nil }
        return "Today: " + segments.joined(separator: " · ")
    }

    /// "Tomorrow: resume GUN-208" — preferred form when the latest stop's
    /// anchor pins a Linear key via the excerpt; falls back to the
    /// excerpt itself when no key is present. F-CTO-T8-E narrow surface.
    private var tomorrowLine: String? {
        guard let stop = eod.tomorrowResume else { return nil }
        let excerpt = stop.excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !excerpt.isEmpty else { return nil }
        return "Tomorrow: resume \(excerpt)"
    }

    private var carryHasContent: Bool {
        !(eod.carryWaitingItems.isEmpty && eod.carryOpenBlockers.isEmpty)
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
