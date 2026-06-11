//
//  InboxFiltering.swift
//  Home redesign — pure filter/count helpers for the NEEDS YOU block.
//  Replaces the view-side IV.A.1 stub (selected filter ignored, every chip
//  counted `items.count`). The SwiftUI body is a thin shell over these.
//

import Foundation

public enum InboxFiltering {

  /// Items admitted by `filter`, narrowed by a case-insensitive substring
  /// `query` over title + sourceMeta. Preserves input order (feeder already
  /// sorts severity → recency).
  public static func filtered(
    _ items: [InboxItem], filter: InboxFilter, query: String
  ) -> [InboxItem] {
    let q = query.trimmingCharacters(in: .whitespaces).lowercased()
    return items.filter { item in
      guard filter.admits(item.kind) else { return false }
      guard !q.isEmpty else { return true }
      return item.title.lowercased().contains(q)
        || item.sourceMeta.lowercased().contains(q)
    }
  }

  /// Per-filter admitted counts for the chip strip.
  public static func counts(_ items: [InboxItem]) -> [InboxFilter: Int] {
    var dict: [InboxFilter: Int] = [:]
    for filter in InboxFilter.allCases {
      dict[filter] = items.count { filter.admits($0.kind) }
    }
    return dict
  }
}
