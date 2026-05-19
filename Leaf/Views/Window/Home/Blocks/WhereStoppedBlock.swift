//
//  WhereStoppedBlock.swift
//  Track 8 / Phase 8.7 — WHERE STOPPED block wired to Phase 8.1 substrate
//  (`DerivedInsights.recentWhereStopped(limit:)`). Tap → Track-7 P3
//  `WorkStateDetailScreen` via `RouteCoordinator.pushHomeWorkState()`.
//

import LeafCore
import SwiftUI

struct WhereStoppedBlock: View {
    let snapshot: WhereStoppedSnapshot?

    @Environment(RouteCoordinator.self) private var coordinator

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text(headerText)
                .leafSectionLabel()
                .foregroundStyle(LeafColor.text.tertiary)

            Button(action: { coordinator.pushHomeWorkState() }) {
                LeafCard(padding: .regular) {
                    cardContent
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Open work state details")
            .accessibilityHint(accessibilityHint)
            .animation(.easeInOut(duration: 0.25), value: snapshot)
        }
    }

    @ViewBuilder
    private var cardContent: some View {
        if hasUsableSnapshot, let snap = snapshot {
            populatedBody(snap)
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        LeafEmptyState(
            icon: LeafIcons.brand.leaf,
            title: "Last work context",
            description: "No recent stop-points captured."
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func populatedBody(_ snap: WhereStoppedSnapshot) -> some View {
        let cleanWipSignals = snap.wipSignals
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return VStack(alignment: .leading, spacing: LeafSpace.sm) {
            Text(snap.excerpt)
                .font(LeafType.title.small)
                .foregroundStyle(LeafColor.text.primary)
                .lineLimit(2)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)

            if !cleanWipSignals.isEmpty {
                Text(cleanWipSignals.joined(separator: " · "))
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Treats a snapshot with empty `excerpt` as no-data — header drops age
    /// suffix and card falls back to `emptyState`. Substrate today never
    /// emits empty excerpts, but this defends against future producer regressions.
    private var hasUsableSnapshot: Bool {
        guard let snap = snapshot else { return false }
        return !snap.excerpt.isEmpty
    }

    private var headerText: String {
        guard hasUsableSnapshot, let snap = snapshot else { return "WHERE YOU STOPPED" }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let delta = max(0, nowMs - snap.generatedAtMs)
        return "WHERE YOU STOPPED · \(HomeRelativeTimeFormatter.format(deltaMs: delta, nowMs: nowMs))"
    }

    private var accessibilityHint: String {
        hasUsableSnapshot
            ? "Opens decisions, open questions, blockers, and where-stopped history."
            : "No recent stop-points. Opens full detector history."
    }
}
