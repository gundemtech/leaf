//
//  Sidebar.swift
//  Track 2 / D2 — three-group sidebar (LEAF / COLLABORATION / ACCOUNT) на
//  LeafNavRow (D1 organism O3). Grouping живёт исключительно тут — каждая
//  Section хардкодит свои WindowSection cases. Badge slot и shortcut slot
//  пустые (D2 baseline; D3+ может wire'нуть для Activity unread / etc).
//

import SwiftUI

struct Sidebar: View {
    @Binding var selection: WindowSection

    var body: some View {
        List(selection: $selection) {
            section(title: "LEAF", items: [.home, .activity])
            section(title: "COLLABORATION", items: [.team, .connections, .organization])
            section(title: "ACCOUNT", items: [.settings, .profile])
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func section(title: String, items: [WindowSection]) -> some View {
        Section {
            ForEach(items) { item in
                navRow(for: item)
                    .tag(item)
            }
        } header: {
            Text(title)
                .leafSectionLabel()
                .foregroundStyle(LeafColor.text.tertiary)
        }
    }

    @ViewBuilder
    private func navRow(for item: WindowSection) -> some View {
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
