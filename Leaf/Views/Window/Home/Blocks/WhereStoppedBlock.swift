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

            LeafCard(padding: .regular) {
                cardContent
            }
        }
    }

    @ViewBuilder
    private var cardContent: some View {
        if snapshot == nil {
            emptyState
        } else {
            EmptyView()
        }
    }

    private var emptyState: some View {
        LeafEmptyState(
            icon: LeafIcons.brand.leaf,
            title: "Last work context",
            description: "No recent stop-points captured."
        )
    }

    private var headerText: String {
        "WHERE YOU STOPPED"
    }
}
