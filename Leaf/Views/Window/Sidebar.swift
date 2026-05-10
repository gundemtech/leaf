//
//  Sidebar.swift
//  Track 2 / D2 — three-group sidebar (LEAF / COLLABORATION / ACCOUNT) на
//  LeafNavRow (D1 organism O3). Grouping живёт исключительно тут — каждая
//  группа хардкодит свои WindowSection cases. Badge slot и shortcut slot
//  пустые (D2 baseline; D3+ может wire'нуть для Activity unread / etc).
//
//  Render pattern matches LeafNavRowPreview (TokensPreview) — flat VStack,
//  not List. macOS' List(selection:) с .listStyle(.sidebar) накладывает
//  native sidebar selection chrome (saturated accent fill) поверх
//  LeafNavRow's own accent.subtle background — design-system intent
//  единственно one source of truth for selection visuals: LeafNavRow.
//

import SwiftUI

struct Sidebar: View {
    @Binding var selection: WindowSection

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: LeafSpace.lg) {
                group(title: "LEAF", items: [.home, .activity])
                group(title: "COLLABORATION", items: [.team, .connections, .organization])
                group(title: "ACCOUNT", items: [.settings, .profile])
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func group(title: String, items: [WindowSection]) -> some View {
        VStack(alignment: .leading, spacing: LeafSpace.xs) {
            Text(title)
                .leafSectionLabel()
                .foregroundStyle(LeafColor.text.tertiary)
                .padding(.horizontal, LeafSpace.md)

            VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                ForEach(items) { item in
                    LeafNavRow(
                        icon: item.iconIsSystem ? .system(item.icon) : .asset(item.icon),
                        title: item.title,
                        isSelected: Binding(
                            get: { selection == item },
                            set: { if $0 { selection = item } }
                        ),
                        onTap: { selection = item }
                    )
                }
            }
        }
    }
}
