//
//  AnalyticsView.swift
//  Track-9 T9 — Analytics surface state-machine wrapper. Replaces the
//  Phase 8.8 P8 placeholder ("Analytics view coming soon"). Reads
//  InsightsReader.State (mirror HomeView Track-8 P3 pattern + T6
//  last-known retention for graceful error degrade).
//
//  Routes:
//    .loading        → "Reading weekly metrics…" inline scaffold
//    .notConfigured  → LeafCard + LeafEmptyState (full-page placeholder)
//    .empty          → LeafCard + LeafEmptyState (full-page placeholder)
//    .error          → LeafBanner.danger + AnalyticsContent(last-known)
//    .loaded         → AnalyticsContent(metrics: snapshot.weeklyMetrics)
//
//  Substrate-purity: zero new event_kinds / migrations / MCP tools.
//

import LeafCore
import SwiftUI

struct AnalyticsView: View {
    @Environment(InsightsReader.self) private var reader

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: LeafSpace.xl) {
                header
                stateContent
            }
            .padding(LeafSpace.xl)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { reader.refresh() }
    }

    private var header: some View {
        Text("Analytics")
            .font(LeafType.title.large)
            .foregroundStyle(LeafColor.text.primary)
    }

    @ViewBuilder
    private var stateContent: some View {
        switch reader.state {
        case .loading:
            loadingState
        case .notConfigured(let msg):
            LeafCard(padding: .regular) {
                LeafEmptyState(
                    icon: LeafIcons.brand.leaf,
                    title: "Not configured",
                    description: msg
                )
            }
        case .empty(let msg):
            LeafCard(padding: .regular) {
                LeafEmptyState(
                    icon: LeafIcons.brand.leaf,
                    title: "No data yet",
                    description: msg
                )
            }
        case .error(let msg, let lastKnown):
            VStack(alignment: .leading, spacing: LeafSpace.lg) {
                LeafBanner(
                    tone: .danger,
                    title: "Couldn't load analytics",
                    description: msg,
                    ctaTitle: "Try again",
                    onCTA: { reader.refresh() }
                )
                AnalyticsContent(metrics: lastKnown?.weeklyMetrics ?? .empty)
            }
        case .loaded(let snapshot, _):
            AnalyticsContent(metrics: snapshot.weeklyMetrics)
        }
    }

    private var loadingState: some View {
        VStack(alignment: .leading, spacing: LeafSpace.sm) {
            Text("Reading weekly metrics…")
                .font(LeafType.title.medium)
                .foregroundStyle(LeafColor.text.secondary)
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
        }
    }
}
