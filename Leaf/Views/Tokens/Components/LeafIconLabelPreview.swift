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
                LeafIconLabel(icon: "leaf",       title: "Leading",  alignment: .leading)
                LeafIconLabel(icon: "circle.fill", title: "Centered", alignment: .centered)
                LeafIconLabel(icon: "checkmark",  title: "Trailing", alignment: .trailing)
            }

            TokensInlineSpec(
                spec: "LeafIconLabel · icon + title · leading / centered / trailing · LeafIcon md + LeafType.body.regular",
                codeSnippet: "LeafIconLabel(icon: \"leaf\", title: \"Active\", alignment: .leading)"
            )
        }
        .padding(LeafSpace.lg)
        .background(LeafColor.surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
    }
}
#endif
