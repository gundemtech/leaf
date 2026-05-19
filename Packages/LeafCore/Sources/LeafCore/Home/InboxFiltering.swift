//
//  InboxFiltering.swift
//  Phase 8.9 (P9) — C-17 extraction of InboxBlock.filteredItems logic.
//  Pure function over [InboxItem] inputs, delegating filter chip semantics
//  to existing `InboxFilter.admits(_:)` predicate so the view layer is
//  unit-testable without SwiftUI.
//

import Foundation

public enum InboxFiltering {
    /// Filter and search [InboxItem] against a filter chip + free-text query.
    /// - Parameters:
    ///   - items: source items (snapshot from substrate).
    ///   - filter: chip selection. `.all` admits any kind; other cases admit
    ///       only their matching `InboxKind`.
    ///   - query: free-text. Empty string → no text filter. Non-empty →
    ///       whitespace-trimmed, case-insensitive substring match against
    ///       `title || sourceMeta`.
    public static func filtered(
        items: [InboxItem], filter: InboxFilter, query: String
    ) -> [InboxItem] {
        let byFilter = items.filter { filter.admits($0.kind) }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return byFilter }
        return byFilter.filter { item in
            item.title.lowercased().contains(trimmed)
                || item.sourceMeta.lowercased().contains(trimmed)
        }
    }
}
