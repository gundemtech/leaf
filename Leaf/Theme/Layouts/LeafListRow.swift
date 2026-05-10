//
//  LeafListRow.swift
//  Track 2 / D1 — Organism O4. 2-line list row with leading + trailing slots
//  and hover state. Used in tables (Connections, Activity feed, Team grid).
//

import SwiftUI

struct LeafListRow<Leading: View, Trailing: View>: View {
    let primary: String
    let secondary: String?
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    @State private var hover = false

    var body: some View {
        HStack(spacing: LeafSpace.md) {
            leading()
            VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                Text(primary)
                    .font(LeafType.body.regular)
                    .foregroundStyle(LeafColor.text.primary)
                if let secondary {
                    Text(secondary)
                        .font(LeafType.body.small)
                        .foregroundStyle(LeafColor.text.tertiary)
                }
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, LeafListRowTokens.horizontalPadding)
        .padding(.vertical, LeafListRowTokens.verticalPadding)
        .background(
            RoundedRectangle(cornerRadius: LeafListRowTokens.cornerRadius, style: .continuous)
                .fill(hover ? LeafColor.surface.raised : Color.clear)
        )
        .onHover { hover = $0 }
        .leafAnimation(LeafMotion.spring.snappy, value: hover)
    }
}

extension LeafListRow where Leading == EmptyView, Trailing == EmptyView {
    init(primary: String, secondary: String? = nil) {
        self.primary = primary
        self.secondary = secondary
        self.leading = { EmptyView() }
        self.trailing = { EmptyView() }
    }
}

extension LeafListRow where Trailing == EmptyView {
    init(
        primary: String,
        secondary: String? = nil,
        @ViewBuilder leading: @escaping () -> Leading
    ) {
        self.primary = primary
        self.secondary = secondary
        self.leading = leading
        self.trailing = { EmptyView() }
    }
}

extension LeafListRow where Leading == EmptyView {
    init(
        primary: String,
        secondary: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.primary = primary
        self.secondary = secondary
        self.leading = { EmptyView() }
        self.trailing = trailing
    }
}
