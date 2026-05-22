//
//  AdvancedSettingsSection.swift
//  Track-10 T1 — power-user toggles. Currently 1 row (Show Analytics tab),
//  drives Sidebar filter via `@AppStorage("leaf.ui.showAnalyticsSection")`.
//  Hidden by default per master spec §3.8 — Analytics tab + 6 block files
//  stay on disk (reversible), only the sidebar entry is filtered.
//

import SwiftUI

struct AdvancedSettingsSection: View {
    @AppStorage("leaf.ui.showAnalyticsSection") private var showAnalytics: Bool = false

    var body: some View {
        LeafSection(
            title: "Advanced",
            description:
                "Power-user toggles. These are off by default — turn them on if you know what you're looking for."
        ) {
            LeafCard(variant: .raised, padding: .regular, header: { EmptyView() }) {
                Toggle(isOn: $showAnalytics) {
                    VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                        Text("Show Analytics tab")
                            .font(LeafType.body.regular)
                            .foregroundStyle(LeafColor.text.primary)
                        Text(
                            "Restore the Analytics tab in the sidebar. Hidden by default — its data is still captured."
                        )
                        .font(LeafType.body.small)
                        .foregroundStyle(LeafColor.text.secondary)
                    }
                }
                .toggleStyle(.switch)
                .tint(LeafColor.accent.primary)
            } footer: {
                EmptyView()
            }
        }
    }
}
