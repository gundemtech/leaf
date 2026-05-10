//
//  LeafIconLabelPreview.swift
//  Track 2 / D1 — TokensPreview entry for Molecule M9 LeafIconLabel.
//

import SwiftUI

#if DEBUG
struct LeafIconLabelPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("LeafIconLabel").font(LeafType.title.medium).foregroundStyle(LeafColor.text.primary)

            VStack(alignment: .leading, spacing: LeafSpace.sm) {
                LeafIconLabel(icon: .asset(LeafIcons.brand.leafFill),    title: "Leading",  alignment: .leading)
                LeafIconLabel(icon: .asset(LeafIcons.status.successFill), title: "Centered", alignment: .centered)
                LeafIconLabel(icon: .asset(LeafIcons.status.info),       title: "Trailing", alignment: .trailing)
            }

            TokensInlineSpec(
                spec: "LeafIconLabel · icon (asset|system) + title · leading / centered / trailing · LeafIcon md + LeafType.body.regular",
                codeSnippet: "LeafIconLabel(icon: .asset(LeafIcons.brand.leafFill), title: \"Active\", alignment: .leading)"
            )
        }
        .padding(LeafSpace.lg)
        .background(LeafColor.surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
    }
}
#endif
