//
//  LeafSheetLayoutPreview.swift
//  Track 2 / D1 — TokensPreview entry for Template T2 LeafSheetLayout.
//  LeafSheetLayout enforces minWidth:480 / minHeight:360 (sheet ergonomic
//  floor) which exceeds the inline section frame, so the preview renders
//  a static mockup that diagrams toolbar + content + glass background
//  using the same tokens. Production usage stays identical to the
//  codeSnippet below.
//

import SwiftUI

#if DEBUG
struct LeafSheetLayoutPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.sm) {
            Text("LeafSheetLayout").font(LeafType.title.medium)
                .foregroundStyle(LeafColor.text.primary)

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("Invite teammate")
                        .font(LeafType.title.medium)
                        .foregroundStyle(LeafColor.text.primary)
                    Spacer()
                    LeafIconButton(asset: LeafIcons.action.close, variant: .ghost, size: .md, action: {})
                }
                .padding(.horizontal, LeafSpace.lg)
                .padding(.vertical, LeafSpace.sm)
                LeafDivider()
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
                        LeafButton("Cancel", variant: .secondary, action: {})
                        LeafButton("Send invite", variant: .primary, action: {})
                    }
                }
                .padding(LeafSpace.lg)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(height: 280)
            .leafGlass(.regular, cornerRadius: LeafRadius.lg)

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
