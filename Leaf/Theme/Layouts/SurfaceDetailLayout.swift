//
//  SurfaceDetailLayout.swift
//  Track 7 P1 — reusable scaffold for all 9 detail screens (spec §5.1).
//  4 sections: range tab strip → headline → chart slot → aggregates slot.
//  Recent events stay outside this layout (rendered by the screen below
//  the layout) so the screen can decide whether to wrap in LeafSection
//  + LeafCard or render inline.
//
//  Range tab is a binding so the screen view-model owns selection state
//  and re-queries Derived Insights when it changes.
//

import SwiftUI
import LeafCore

struct DetailHeadline: Equatable {
    let value: String
    /// Optional trend annotation, rendered next to the value. Spec §5.4 —
    /// view-model decides whether to include this (omit if prev period has
    /// less than 50% expected days).
    let trend: String?
}

struct SurfaceDetailLayout<Aggregates: View, Chart: View>: View {
    let title: String
    @Binding var range: DetailRange
    let headline: DetailHeadline
    @ViewBuilder let chart: () -> Chart
    @ViewBuilder let aggregates: () -> Aggregates

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LeafSpace.xl) {
                rangeTabStrip
                headlineBlock
                chartBlock
                aggregatesBlock
            }
            .padding(LeafSpace.xxl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(title)
    }

    private var rangeTabStrip: some View {
        LeafTab(
            selection: $range,
            tabs: DetailRange.allCases,
            label: { tab in
                switch tab {
                case .today: "Today"
                case .week:  "Week"
                case .month: "Month"
                }
            }
        )
    }

    private var headlineBlock: some View {
        VStack(alignment: .leading, spacing: LeafSpace.xs) {
            Text(headline.value)
                .font(LeafType.title.large)
                .foregroundStyle(LeafColor.text.primary)
            if let trend = headline.trend {
                Text(trend)
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.tertiary)
            }
        }
    }

    private var chartBlock: some View {
        LeafCard(padding: .regular) {
            chart()
                .frame(height: LeafSpace.xxxxl + LeafSpace.xxxl)   // 112pt ≈ spec §5.1 ~120pt
        }
    }

    private var aggregatesBlock: some View {
        aggregates()
    }
}
