//
//  InboxFilterRow.swift
//  Track 8 / Phase 8.6 — INBOX filter chip row. LeafPill chips
//  (All / Reviews / Questions / Mentions / Alerts) bound to a Binding<InboxFilter>.
//  Selected chip uses `.accent` tone, others `.neutral`.
//  Track-9 T8 — added `.alerts` chip (buildFailed + ciFailed + liveMeeting umbrella).
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
        (.alerts, "Alerts"),
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
                .accessibilityAddTraits(selected == chip.filter ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}
