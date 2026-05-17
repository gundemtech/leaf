//
//  LeafWindowLayoutTokens.swift
//  Track 2 / D1 — T3 tokens for Template T1 LeafWindowLayout. Sidebar column
//  width range surfaced so split-view sizing is one-line tunable without
//  editing the template body.
//

import CoreGraphics

enum LeafWindowLayoutTokens {
    static let sidebarMinWidth: CGFloat = 220
    static let sidebarIdealWidth: CGFloat = 260
    static let sidebarMaxWidth: CGFloat = 320

    /// Track 2 / D2 — overall window minimum size constraint applied at
    /// RootView. Gives the split view enough room for sidebar at min width
    /// + meaningful detail content. Adjust here, not at consumer call site.
    static let windowMinWidth: CGFloat = 920
    static let windowMinHeight: CGFloat = 620
}
