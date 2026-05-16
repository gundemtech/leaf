//
//  LeafFilterChipsPreview.swift
//  Track 5 / S7 B.6 — TokensPreview entry for LeafFilterChips.
//
//  Variants:
//  1. Default — All selected (initial state, only .all chip active)
//  2. Multi-select — Direct Messages + My Decisions selected (.all cleared)
//  3. Popover active — More pill highlighted (shareSource filters selected)
//  4. Empty-guard — after toggling last item, .all restored automatically
//

import SwiftUI
import LeafCore

#if DEBUG
struct LeafFilterChipsPreview: View {

    // MARK: - Shared filter configuration

    /// First 5 shown inline.
    private let visible: [FeedFilter] = [
        .all,
        .directMessages,
        .openTasks,
        .decisions,
        .blockers,
    ]

    /// ShareSource cases shown inside More… popover.
    private let popover: [FeedFilter] = ShareSource.allCases.map { .shareSource($0) }

    // MARK: - Per-variant state

    @State private var selected1: Set<FeedFilter> = [.all]
    @State private var selected2: Set<FeedFilter> = [.directMessages, .decisions]
    @State private var selected3: Set<FeedFilter> = [.shareSource(.gitCommits), .shareSource(.linearIssues)]
    @State private var selected4: Set<FeedFilter> = [.all]   // will restore to [.all] on deselect

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LeafSpace.xl) {
                Text("LeafFilterChips")
                    .font(LeafType.title.medium)
                    .foregroundStyle(LeafColor.text.primary)

                // ── Variant 1 — default .all ──────────────────────────────────
                sectionLabel("1 · Default — only .all active")
                LeafFilterChips(
                    visibleFilters: visible,
                    popoverFilters: popover,
                    selected: $selected1
                )
                selectedCaption(selected1)

                // ── Variant 2 — multi-select (no .all) ───────────────────────
                sectionLabel("2 · Multi-select — Direct Messages + My Decisions")
                LeafFilterChips(
                    visibleFilters: visible,
                    popoverFilters: popover,
                    selected: $selected2
                )
                selectedCaption(selected2)

                // ── Variant 3 — popover sources selected (More pill accented) ─
                sectionLabel("3 · More… active — two ShareSource filters")
                LeafFilterChips(
                    visibleFilters: visible,
                    popoverFilters: popover,
                    selected: $selected3
                )
                selectedCaption(selected3)

                // ── Variant 4 — interactive empty-guard demo ──────────────────
                sectionLabel("4 · Tap to deselect last → auto-restore .all")
                LeafFilterChips(
                    visibleFilters: visible,
                    popoverFilters: popover,
                    selected: $selected4
                )
                selectedCaption(selected4)

                // ── Spec note ─────────────────────────────────────────────────
                TokensInlineSpec(
                    spec: "LeafFilterChips · 5 visible + More popover · mutex .all",
                    codeSnippet: "LeafFilterChips(visibleFilters:popoverFilters:selected:)"
                )
            }
            .padding(LeafSpace.lg)
        }
        .background(LeafColor.surface.canvas)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
        .frame(width: 560)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .leafSectionLabel()
            .foregroundStyle(LeafColor.text.tertiary)
    }

    @ViewBuilder
    private func selectedCaption(_ set: Set<FeedFilter>) -> some View {
        let labels = set.map(\.displayLabel).sorted().joined(separator: ", ")
        Text("selected: \(labels)")
            .font(LeafType.caption)
            .foregroundStyle(LeafColor.text.tertiary)
    }
}

#Preview("LeafFilterChips") {
    LeafFilterChipsPreview()
        .padding()
}
#endif
