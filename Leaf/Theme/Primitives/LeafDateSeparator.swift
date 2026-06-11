//
//  LeafDateSeparator.swift
//  Team UI polish — "── Today ──" day separator for the Team feed.
//  Labels come from TeamFeedPresentation.daySections (LeafCore).
//

import SwiftUI

struct LeafDateSeparator: View {
  let label: String

  var body: some View {
    HStack(spacing: LeafSpace.sm) {
      line
      Text(label)
        .font(LeafType.caption)
        .foregroundStyle(LeafColor.text.tertiary)
        .fixedSize()
      line
    }
    .padding(.vertical, LeafSpace.sm)
    .accessibilityElement(children: .combine)
  }

  private var line: some View {
    Rectangle()
      .fill(LeafColor.border.subtle)
      .frame(height: 1)
      .frame(maxWidth: .infinity)
  }
}
