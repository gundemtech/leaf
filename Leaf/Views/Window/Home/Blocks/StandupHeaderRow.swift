//
//  StandupHeaderRow.swift
//  Track-10 T8 — shared chevron header for RecapBlock + EodBlock.
//  Always-visible (master spec §3.7 / Brainstorm Q4) — body expands /
//  collapses via the chevron rotation animation; tap target fills the
//  row width with a ≥44pt hit target per HIG (F-CTO-T8-O lock).
//
//  Accessibility:
//  - Combined element so VoiceOver reads label + subtitle + state as one
//  - `.isHeader + .isButton` traits so VO treats the row as a tappable
//    section header
//

import LeafCore
import SwiftUI

struct StandupHeaderRow: View {
    let label: String
    let subtitle: String
    let expanded: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: LeafSpace.sm) {
                Image(systemName: "chevron.down")
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.tertiary)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
                    .animation(.easeOut(duration: 0.15), value: expanded)
                    // LeafSpace.md = 12pt chevron container (semantic mapping).
                    .frame(width: LeafSpace.md)
                    .accessibilityHidden(true)
                Text(label)
                    .leafSectionLabel()
                    .foregroundStyle(LeafColor.text.tertiary)
                Text(subtitle)
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, LeafSpace.xs)
            .contentShape(Rectangle())
            .frame(minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(subtitle)")
        .accessibilityValue(expanded ? "expanded" : "collapsed")
        .accessibilityAddTraits([.isButton, .isHeader])
        .accessibilityHint("Double-tap to \(expanded ? "collapse" : "expand")")
    }
}
