//
//  TokensIconsSection.swift
//  Track 2 / D1 — Inventory of every glyph used across the app, grouped by
//  semantic purpose. Custom Figma SVG set (template-rendered) для всего, кроме
//  search / filter — те остаются SF Symbols по design-call'у.
//

import SwiftUI

#if DEBUG
struct TokensIconsSection: View {
    private enum Source {
        case asset(String)
        case system(String)

        var displayName: String {
            switch self {
            case .asset(let n):  return n
            case .system(let n): return n
            }
        }
    }

    private struct IconItem: Identifiable {
        let id: String
        let label: String
        let source: Source
    }

    private struct IconGroup: Identifiable {
        let id: String
        let title: String
        let items: [IconItem]
    }

    private let groups: [IconGroup] = [
        IconGroup(id: "brand", title: "Brand", items: [
            IconItem(id: "brand.leaf",      label: "leaf",      source: .asset(LeafIcons.brand.leaf)),
            IconItem(id: "brand.leaf.fill", label: "leaf.fill", source: .asset(LeafIcons.brand.leafFill)),
        ]),
        IconGroup(id: "actions", title: "Actions", items: [
            IconItem(id: "act.close",            label: "close",              source: .asset(LeafIcons.action.close)),
            IconItem(id: "act.clear",            label: "clear",              source: .asset(LeafIcons.action.clear)),
            IconItem(id: "act.add",              label: "add",                source: .asset(LeafIcons.action.add)),
            IconItem(id: "act.add.fill",         label: "add (filled)",       source: .asset(LeafIcons.action.addFill)),
            IconItem(id: "act.overflow",         label: "overflow",           source: .asset(LeafIcons.action.overflow)),
            IconItem(id: "act.overflow.fill",    label: "overflow (filled)",  source: .asset(LeafIcons.action.overflowFill)),
            IconItem(id: "act.refresh",          label: "refresh",            source: .asset(LeafIcons.action.refresh)),
            IconItem(id: "act.external",         label: "external link",      source: .asset(LeafIcons.action.external)),
        ]),
        IconGroup(id: "nav", title: "Navigation", items: [
            IconItem(id: "nav.home",         label: "home",         source: .asset(LeafIcons.nav.home)),
            IconItem(id: "nav.activity",     label: "activity",     source: .asset(LeafIcons.nav.activity)),
            IconItem(id: "nav.team",         label: "team",         source: .asset(LeafIcons.nav.team)),
            IconItem(id: "nav.connections",  label: "connections",  source: .asset(LeafIcons.nav.connections)),
            IconItem(id: "nav.settings",     label: "settings",     source: .asset(LeafIcons.nav.settings)),
            IconItem(id: "nav.profile",      label: "profile",      source: .asset(LeafIcons.nav.profile)),
            IconItem(id: "nav.sidebar",      label: "sidebar",      source: .asset(LeafIcons.nav.sidebar)),
            IconItem(id: "nav.organization", label: "organization (SF)", source: .system(LeafIcons.nav.organizationSF)),
            IconItem(id: "nav.search",       label: "search (SF)",  source: .system(LeafIcons.nav.searchSF)),
            IconItem(id: "nav.filter",       label: "filter (SF)",  source: .system(LeafIcons.nav.filterSF)),
        ]),
        IconGroup(id: "comm", title: "Communication", items: [
            IconItem(id: "comm.email",   label: "invite / email",   source: .asset(LeafIcons.comm.email)),
            IconItem(id: "comm.message", label: "comment / chat",   source: .asset(LeafIcons.comm.message)),
            IconItem(id: "comm.copy",    label: "copy",             source: .asset(LeafIcons.comm.copy)),
            IconItem(id: "comm.share",   label: "share",            source: .asset(LeafIcons.comm.share)),
        ]),
        IconGroup(id: "status", title: "Status", items: [
            IconItem(id: "stat.success",      label: "success",            source: .asset(LeafIcons.status.success)),
            IconItem(id: "stat.success.fill", label: "success (filled)",   source: .asset(LeafIcons.status.successFill)),
            IconItem(id: "stat.warning",      label: "warning",            source: .asset(LeafIcons.status.warning)),
            IconItem(id: "stat.warning.fill", label: "warning (filled)",   source: .asset(LeafIcons.status.warningFill)),
            IconItem(id: "stat.info",         label: "info",               source: .asset(LeafIcons.status.info)),
        ]),
        IconGroup(id: "obj", title: "Object", items: [
            IconItem(id: "obj.trash",     label: "delete / revoke",   source: .asset(LeafIcons.object.trash)),
            IconItem(id: "obj.app",       label: "app placeholder",   source: .asset(LeafIcons.object.appPlaceholder)),
            IconItem(id: "obj.folder",    label: "empty folder",      source: .asset(LeafIcons.object.folderEmpty)),
            IconItem(id: "obj.user.err",  label: "user error",        source: .asset(LeafIcons.object.userError)),
        ]),
        IconGroup(id: "metric", title: "Metric arrows", items: [
            IconItem(id: "m.up",   label: "delta up",    source: .asset(LeafIcons.metric.up)),
            IconItem(id: "m.down", label: "delta down",  source: .asset(LeafIcons.metric.down)),
            IconItem(id: "m.flat", label: "delta flat",  source: .asset(LeafIcons.metric.flat)),
        ]),
    ]

    private var totalCount: Int { groups.reduce(0) { $0 + $1.items.count } }
    private var customCount: Int {
        groups.reduce(0) { acc, g in
            acc + g.items.filter { if case .asset = $0.source { true } else { false } }.count
        }
    }

    private let columns: [GridItem] = Array(
        repeating: GridItem(.flexible(), spacing: LeafSpace.md),
        count: 6
    )

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.lg) {
            HStack(alignment: .firstTextBaseline) {
                Text("Icons").font(LeafType.title.large).foregroundStyle(LeafColor.text.primary)
                Spacer()
                Text("\(customCount) custom · \(totalCount - customCount) SF Symbol · 24×24 template-rendered")
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
            iconView(item.source)
                .frame(maxWidth: .infinity, minHeight: LeafSpace.xxxl)

            Text(item.label)
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)

            Text(item.source.displayName)
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

    @ViewBuilder
    private func iconView(_ source: Source) -> some View {
        switch source {
        case .asset(let name):
            LeafIcon(asset: name, size: .lg, tint: LeafColor.text.primary)
        case .system(let name):
            LeafIcon(systemName: name, size: .lg, tint: LeafColor.text.primary)
        }
    }
}
#endif
