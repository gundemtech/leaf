//
//  ChipAccessibility.swift
//  Track-10 Phase A (GUN-A) — hoists the Button-wrapped LeafPill chip
//  a11y pattern that drifted across Home filter rows (NeedsYouFilterRow /
//  SinceFilterRow / WeekChipStrip) into one view modifier.
//
//  Applied to the Button (not LeafPill itself — LeafPill is a label that
//  may or may not be wrapped in a Button). The Button auto-inherits the
//  `.isButton` trait; the modifier adds:
//    - explicit `.accessibilityLabel` (override LeafPill's title text +
//      surrounding count/state, written with pluralization)
//    - `.isSelected` trait when the chip represents the active filter
//
//  Reduces drift on `.isSelected` semantics across blocks; future chip-
//  strip blocks adopt this modifier instead of hand-rolling 2-3 a11y
//  modifier chains.
//

import SwiftUI

extension View {
    /// Apply consistent accessibility to a Button-wrapped LeafPill chip:
    /// label override + `.isSelected` trait when active. Place after
    /// `.buttonStyle(.plain)` so the modifier wraps the button's
    /// accessibility node, not its label.
    func leafChipAccessibility(label: String, isSelected: Bool) -> some View {
        accessibilityLabel(label)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
