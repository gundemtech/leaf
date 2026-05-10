//
//  MetricsSection.swift
//  Track 2 / D1 — populated by Tasks 35–38 (MT1 Inline / MT2 Ambient / MT3 Delta / MT4 Sparkline).
//

import SwiftUI

#if DEBUG
struct MetricsSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.xl) {
            Text("Metrics").font(LeafType.title.large).foregroundStyle(LeafColor.text.primary)
            LeafMetricInlinePreview()
            LeafMetricAmbientPreview()
            LeafMetricDeltaPreview()
            LeafSparklinePreview()
            LeafMetricCardPreview()
        }
    }
}
#endif
