//
//  LeafMetricInline.swift
//  Track 2 / D1 — Metric MT1. Inline-in-narrative number with tabular figures.
//  Sits on the same baseline as surrounding body text; emphasis comes from
//  monospaced digits + primary text colour, not weight or size jumps.
//

import SwiftUI

struct LeafMetricInline: View {
    let value: String

    var body: some View {
        Text(value)
            .font(LeafMetricTokens.Inline.font)
            .foregroundStyle(LeafMetricTokens.Inline.foreground)
    }
}
