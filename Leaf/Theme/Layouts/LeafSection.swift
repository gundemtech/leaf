//
//  LeafSection.swift
//  Track 2 / D1 — Organism O2. Title / optional description / content slot
//  with optional CTA pinned top-right. Used to label sub-blocks within a
//  pane (Settings, Connections, Team detail).
//

import SwiftUI

struct LeafSection<Content: View, CTA: View>: View {
    let title: String
    var description: String? = nil
    @ViewBuilder let content: () -> Content
    @ViewBuilder let cta: () -> CTA

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                    Text(title)
                        .font(LeafSectionTokens.titleFont)
                        .foregroundStyle(LeafColor.text.primary)
                    if let description {
                        Text(description)
                            .font(LeafSectionTokens.descriptionFont)
                            .foregroundStyle(LeafColor.text.secondary)
                    }
                }
                Spacer()
                cta()
            }
            content()
        }
    }
}

extension LeafSection where CTA == EmptyView {
    init(
        title: String,
        description: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.description = description
        self.content = content
        self.cta = { EmptyView() }
    }
}
