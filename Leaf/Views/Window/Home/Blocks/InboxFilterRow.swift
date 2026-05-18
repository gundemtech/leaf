//
//  InboxFilterRow.swift
//  Track 8 / Phase 8.6 — INBOX filter chip row. 4 LeafPill chips
//  (All / Reviews / Questions / Mentions) bound to a Binding<InboxFilter>.
//  Selected chip uses `.accent` tone, others `.neutral`.
//

import LeafCore
import SwiftUI

struct InboxFilterRow: View {
    @Binding var selected: InboxFilter

    private static let chips: [(filter: InboxFilter, label: String)] = [
        (.all, "All"),
        (.reviews, "Reviews"),
        (.questions, "Questions"),
        (.mentions, "Mentions"),
    ]

    var body: some View {
        HStack(spacing: LeafSpace.xs) {
            ForEach(Self.chips, id: \.filter) { chip in
                Button {
                    selected = chip.filter
                } label: {
                    LeafPill(
                        title: chip.label,
                        tone: selected == chip.filter ? .accent : .neutral
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(chip.label) filter")
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(selected == chip.filter ? "Selected" : "Tap to filter")
            }
        }
    }
}
