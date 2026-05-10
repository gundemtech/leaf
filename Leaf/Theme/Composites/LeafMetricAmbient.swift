//
//  LeafMetricAmbient.swift
//  Track 2 / D1 — Metric MT2. Large quiet display number + tertiary label.
//  No card chrome — sits directly on canvas. Used for "headline" metrics on
//  Home / Team views where the number deserves visual weight on its own.
//

import SwiftUI

struct LeafMetricAmbient: View {
    let value: String
    let label: String
    var valueTint: Color = LeafColor.text.primary

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.xs) {
            Text(value)
                .font(LeafMetricTokens.Ambient.valueFont)
                .foregroundStyle(valueTint)
            Text(label)
                .font(LeafMetricTokens.Ambient.labelFont)
                .foregroundStyle(LeafColor.text.tertiary)
        }
    }
}
