//
//  LeafSheetLayout.swift
//  Track 2 / D1 — Template T2. Sheet wrapper with LeafToolbar header
//  (title + dismiss icon button) and a glass background. Minimum frame
//  surfaced via LeafSheetLayoutTokens.
//

import SwiftUI

struct LeafSheetLayout<Content: View>: View {
    let title: String
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            LeafToolbar(
                leading: {
                    Text(title)
                        .font(LeafType.title.medium)
                        .foregroundStyle(LeafColor.text.primary)
                },
                center: { EmptyView() },
                trailing: {
                    LeafIconButton(asset: LeafIcons.action.close, variant: .ghost, size: .md, action: onDismiss)
                }
            )
            content()
                .padding(LeafSpace.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(
            minWidth: LeafSheetLayoutTokens.minWidth,
            minHeight: LeafSheetLayoutTokens.minHeight
        )
        .leafGlass(.regular, cornerRadius: LeafRadius.lg)
    }
}
