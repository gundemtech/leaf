//
//  HandoffCardView.swift
//  Use-case rebuild Track C (UC-4) — the landing-page handoff card rendered
//  inside a chat bubble: "● handoff · auth refactor" + PICKING UP badge +
//  four glowing-dot label-value rows + "open full handoff →" (routes to the
//  existing AI "Context for me" sheet when available).
//

import LeafCore
import SwiftUI

struct HandoffCardView: View {
  let snapshot: HandoffContextSnapshot
  /// Inbound bubbles: opens the AI context sheet. nil on outbound (sender's
  /// own preview in the conversation) — the footer hides.
  let onOpenFull: (() -> Void)?

  private var rows: [HandoffCardPresentation.Row] {
    HandoffCardPresentation.rows(
      from: snapshot, nowMs: Int64(Date().timeIntervalSince1970 * 1000))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: LeafSpace.sm) {
      LeafTerminalCardHeader(
        dotTone: .success,
        title: HandoffCardPresentation.headerTitle(from: snapshot)
      ) {
        if onOpenFull != nil {
          LeafStatusBadge(text: "PICKING UP")
        }
      }

      ForEach(rows) { row in
        LeafLabelValueRow(
          label: row.label,
          value: row.value,
          accentPrefix: row.accentPrefix,
          showDot: true,
          url: row.url
        )
      }

      if let onOpenFull {
        LeafCardFooterLink(title: "open full handoff", action: onOpenFull)
      }
    }
    .padding(LeafSpace.md)
    .background(
      RoundedRectangle(cornerRadius: LeafRadius.sm, style: .continuous)
        .fill(LeafColor.surface.inset.opacity(0.6))
    )
    .accessibilityElement(children: .combine)
  }
}
