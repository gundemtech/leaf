//
//  LeafTab.swift
//  Track 2 / D1 — Organism O9. Inline segmented tab strip — generic over a
//  Hashable & Identifiable Tab type. Underline indicator on the selected
//  segment, animated between segments via matchedGeometryEffect + a gentle
//  Leaf spring (reduce-motion-respecting via .leafAnimation).
//

import SwiftUI

struct LeafTab<Tab: Hashable & Identifiable>: View {
    @Binding var selection: Tab
    let tabs: [Tab]
    let label: (Tab) -> String

    @Namespace private var ns

    var body: some View {
        HStack(spacing: LeafTabTokens.tabSpacing) {
            ForEach(tabs) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: LeafTabTokens.labelToIndicator) {
                        Text(label(tab))
                            .font(LeafType.body.regular)
                            .foregroundStyle(
                                selection == tab
                                    ? LeafColor.text.primary
                                    : LeafColor.text.tertiary
                            )
                        if selection == tab {
                            Capsule()
                                .fill(LeafColor.accent.primary)
                                .frame(height: LeafTabTokens.indicatorHeight)
                                .matchedGeometryEffect(id: "underline", in: ns)
                        } else {
                            Capsule()
                                .fill(Color.clear)
                                .frame(height: LeafTabTokens.indicatorHeight)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .leafAnimation(LeafMotion.spring.gentle, value: selection)
    }
}
