//
//  TokensIconsSection.swift
//  Track 2 / D1 — Inventory of every glyph used across the app, grouped by
//  semantic purpose. Source-of-truth surface для перехода SF Symbols → custom
//  Figma SVG set: всё, что отрисовано здесь, должно быть покрыто design
//  system'ной библиотекой иконок.
//

import SwiftUI

#if DEBUG
struct TokensIconsSection: View {
    private struct IconItem: Identifiable {
        let id: String          // unique key (symbol + occurrence label, since
        let symbol: String      // some entries reuse the same SF Symbol)
        let label: String       // semantic label
    }

    private struct IconGroup: Identifiable {
        let id: String
        let title: String
        let items: [IconItem]
    }

    private let groups: [IconGroup] = [
        IconGroup(id: "brand", title: "Brand", items: [
            IconItem(id: "brand.leaf",       symbol: "leaf",      label: "leaf"),
            IconItem(id: "brand.leaf.fill", symbol: "leaf.fill", label: "leaf.fill"),
        ]),
        IconGroup(id: "actions", title: "Actions", items: [
            IconItem(id: "act.xmark",          symbol: "xmark",          label: "close"),
            IconItem(id: "act.xmark.circle",   symbol: "xmark.circle",   label: "clear"),
            IconItem(id: "act.plus",           symbol: "plus",           label: "add"),
            IconItem(id: "act.plus.circle",    symbol: "plus.circle",    label: "add (filled)"),
            IconItem(id: "act.ellipsis",       symbol: "ellipsis",       label: "overflow"),
            IconItem(id: "act.ellipsis.c",     symbol: "ellipsis.circle", label: "overflow (filled)"),
            IconItem(id: "act.refresh",        symbol: "arrow.clockwise", label: "refresh"),
            IconItem(id: "act.external",       symbol: "arrow.up.right", label: "external link"),
        ]),
        IconGroup(id: "nav", title: "Navigation", items: [
            IconItem(id: "nav.search", symbol: "magnifyingglass",                       label: "search"),
            IconItem(id: "nav.filter", symbol: "line.3.horizontal.decrease.circle",      label: "filter"),
            IconItem(id: "nav.sidebar", symbol: "sidebar.left",                          label: "sidebar"),
        ]),
        IconGroup(id: "comm", title: "Communication", items: [
            IconItem(id: "comm.envelope", symbol: "envelope",            label: "invite / email"),
            IconItem(id: "comm.message",  symbol: "message",             label: "comment / chat"),
            IconItem(id: "comm.copy",     symbol: "doc.on.doc",          label: "copy"),
            IconItem(id: "comm.share",    symbol: "square.and.arrow.up", label: "share"),
        ]),
        IconGroup(id: "status", title: "Status", items: [
            IconItem(id: "stat.check",     symbol: "checkmark.circle",            label: "success"),
            IconItem(id: "stat.check.f",   symbol: "checkmark.circle.fill",       label: "success (filled)"),
            IconItem(id: "stat.warn",      symbol: "exclamationmark.triangle",    label: "warning"),
            IconItem(id: "stat.warn.f",    symbol: "exclamationmark.triangle.fill", label: "warning (filled)"),
            IconItem(id: "stat.info",      symbol: "info.circle",                 label: "info"),
        ]),
        IconGroup(id: "obj", title: "Object", items: [
            IconItem(id: "obj.trash",   symbol: "trash",                                       label: "delete / revoke"),
            IconItem(id: "obj.app",     symbol: "app.dashed",                                  label: "app placeholder"),
            IconItem(id: "obj.folder",  symbol: "folder.badge.questionmark",                   label: "empty folder"),
            IconItem(id: "obj.user.err", symbol: "person.crop.circle.badge.exclamationmark",   label: "user error"),
        ]),
        IconGroup(id: "metric", title: "Metric arrows", items: [
            IconItem(id: "m.up",    symbol: "arrow.up",    label: "delta up"),
            IconItem(id: "m.down",  symbol: "arrow.down",  label: "delta down"),
            IconItem(id: "m.flat", symbol: "arrow.right", label: "delta flat"),
        ]),
    ]

    private var totalCount: Int { groups.reduce(0) { $0 + $1.items.count } }

    private let columns: [GridItem] = Array(
        repeating: GridItem(.flexible(), spacing: LeafSpace.md),
        count: 6
    )

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.lg) {
            HStack(alignment: .firstTextBaseline) {
                Text("Icons").font(LeafType.title.large).foregroundStyle(LeafColor.text.primary)
                Spacer()
                Text("\(totalCount) glyphs · SF Symbols (migration target → Figma SVG set)")
                    .font(LeafType.mono.small)
                    .foregroundStyle(LeafColor.text.tertiary)
            }

            VStack(alignment: .leading, spacing: LeafSpace.xl) {
                ForEach(groups) { group in
                    groupView(group)
                }
            }
            .padding(LeafSpace.lg)
            .background(LeafColor.surface.raised)
            .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
        }
    }

    @ViewBuilder
    private func groupView(_ group: IconGroup) -> some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text(group.title)
                .font(LeafType.label)
                .foregroundStyle(LeafColor.text.tertiary)
                .textCase(.uppercase)

            LazyVGrid(columns: columns, alignment: .leading, spacing: LeafSpace.md) {
                ForEach(group.items) { tile($0) }
            }
        }
    }

    @ViewBuilder
    private func tile(_ item: IconItem) -> some View {
        VStack(spacing: LeafSpace.xs) {
            LeafIcon(systemName: item.symbol, size: .lg, tint: LeafColor.text.primary)
                .frame(maxWidth: .infinity, minHeight: LeafSpace.xxxl)

            Text(item.label)
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)

            Text(item.symbol)
                .font(LeafType.mono.small)
                .foregroundStyle(LeafColor.text.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
        }
        .padding(LeafSpace.md)
        .frame(maxWidth: .infinity)
        .background(LeafColor.surface.canvas)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.md, style: .continuous))
    }
}
#endif
