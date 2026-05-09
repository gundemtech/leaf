//
//  MetricsSection.swift
//  Track 2 / D1 — Stub. Filled by Tasks 35–38 (LeafMetricInline / Ambient / Delta / Sparkline).
//

import SwiftUI

#if DEBUG
struct MetricsSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.lg) {
            Text("Metrics").font(LeafType.title.large).foregroundStyle(LeafColor.text.primary)
            Text("Pending — populated by Track 2/D1 Tasks 35–38")
                .font(LeafType.body.small).foregroundStyle(LeafColor.text.tertiary)
        }
    }
}
#endif
