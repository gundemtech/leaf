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
        if let snap = snapshot {
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
    }

    private func populatedBody(_ snap: WhereStoppedSnapshot) -> some View {
        VStack(alignment: .leading, spacing: LeafSpace.sm) {
            Text(snap.excerpt)
                .font(LeafType.title.small)
                .foregroundStyle(LeafColor.text.primary)
                .lineLimit(2)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)

            if !snap.wipSignals.isEmpty {
                Text(snap.wipSignals.joined(separator: " · "))
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerText: String {
        guard let snap = snapshot else { return "WHERE YOU STOPPED" }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let delta = max(0, nowMs - snap.generatedAtMs)
        return "WHERE YOU STOPPED · \(Self.formatRelative(delta, nowMs: nowMs))"
    }

    private var accessibilityHint: String {
        snapshot == nil
            ? "No recent stop-points. Opens full detector history."
            : "Opens decisions, open questions, blockers, and where-stopped history."
    }

    private static func formatRelative(_ deltaMs: Int64, nowMs: Int64) -> String {
        let s = deltaMs / 1000
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86_400 { return "\(s / 3600)h ago" }
        if s < 172_800 { return "yesterday" }
        if s < 604_800 { return "\(s / 86_400) days ago" }
        let anchorSec = (nowMs - deltaMs) / 1000
        return absoluteFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(anchorSec)))
    }

    private static let absoluteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d"
        return f
    }()
}
