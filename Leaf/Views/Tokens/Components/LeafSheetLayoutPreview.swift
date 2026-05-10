//
//  LeafSheetLayoutPreview.swift
//  Track 2 / D1 — TokensPreview entry for Template T2 LeafSheetLayout.
//

import SwiftUI

#if DEBUG
struct LeafSheetLayoutPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.sm) {
            Text("LeafSheetLayout").font(LeafType.title.medium)
                .foregroundStyle(LeafColor.text.primary)

            LeafSheetLayout(title: "Invite teammate", onDismiss: {}) {
                VStack(alignment: .leading, spacing: LeafSpace.lg) {
                    Text("Email")
                        .font(LeafType.label)
                        .foregroundStyle(LeafColor.text.tertiary)
                    Text("name@example.com")
                        .font(LeafType.body.regular)
                        .foregroundStyle(LeafColor.text.primary)
                    Spacer()
                    HStack(spacing: LeafSpace.md) {
                        Spacer()
                        LeafSecondaryButton(action: {}) { Text("Cancel") }
                        LeafProminentButton(action: {}) { Text("Send invite") }
                    }
                }
            }
            .frame(width: LeafSheetLayoutTokens.minWidth,
                   height: LeafSheetLayoutTokens.minHeight)
            .scaleEffect(0.55, anchor: .topLeading)
            .frame(width: LeafSheetLayoutTokens.minWidth * 0.55,
                   height: LeafSheetLayoutTokens.minHeight * 0.55)

            TokensInlineSpec(
                spec: "LeafSheetLayout · LeafToolbar header · dismiss xmark · glass regular · radius lg · 480×360 min",
                codeSnippet: "LeafSheetLayout(title: \"Invite teammate\", onDismiss: { ... }) { content }"
            )
        }
        .padding(LeafSpace.lg)
        .background(LeafColor.surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
    }
}
#endif
