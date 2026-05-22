//
//  InboxFilterRow.swift
//  Track 8 / Phase 8.6 — INBOX filter chip row. LeafPill chips bound to a
//  Binding<InboxFilter>. Selected chip uses `.accent` tone, others `.neutral`.
//  Track-9 T8 — added `.alerts` chip (buildFailed + ciFailed + liveMeeting umbrella).
//  Track-10 T4 — added leading `[NEEDS YOU]` chip (.actionable filter) +
//  inline count suffix `· N` per chip, sourced from a count dict computed
//  in the owning block via InboxFiltering.filtered (single source of truth).
//

import LeafCore
import SwiftUI

struct InboxFilterRow: View {
    @Binding var selected: InboxFilter
    let counts: [InboxFilter: Int]

    private static let chips: [(filter: InboxFilter, label: String)] = [
        (.actionable, "NEEDS YOU"),
        (.all, "All"),
        (.reviews, "Reviews"),
        (.questions, "Questions"),
        (.mentions, "Mentions"),
        (.alerts, "Alerts"),
    ]

    var body: some View {
        HStack(spacing: LeafSpace.xs) {
            ForEach(Self.chips, id: \.filter) { chip in
                let count = counts[chip.filter] ?? 0
                Button {
                    selected = chip.filter
                } label: {
                    LeafPill(
                        title: "\(chip.label) · \(count)",
                        tone: selected == chip.filter ? .accent : .neutral
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(chip.label) filter, \(count) items")
                .accessibilityAddTraits(selected == chip.filter ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}
