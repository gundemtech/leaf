//
//  LeafIcons.swift
//  Track 2 / D1 — Custom icon namespace. Asset Catalog template-rendered SVGs
//  designed in Figma, 24×24 artboard, single-fill, foregroundStyle-tinted.
//  Two glyphs (search / filter) intentionally remain SF Symbols — the system
//  versions match the Apple platform conventions tightly enough that custom
//  ones would be visual debt without payoff.
//

import Foundation

enum LeafIcon_Brand {
  static let leaf: String = "leaf-brand-leaf"
  static let leafFill: String = "leaf-brand-leaf-fill"
  /// The real Leaf product mark (spiralled outline leaf) — same art as the
  /// app icon and the website logo. Ships pre-coloured per appearance
  /// (white on dark, ink on light), so render `.original`, don't tint.
  static let logoMark: String = "leaf-logo-mark"
}

enum LeafIcon_Action {
  static let close: String = "leaf-action-close"
  static let clear: String = "leaf-action-clear"
  static let add: String = "leaf-action-add"
  static let addFill: String = "leaf-action-add-fill"
  static let overflow: String = "leaf-action-overflow"
  static let overflowFill: String = "leaf-action-overflow-fill"
  static let refresh: String = "leaf-action-refresh"
  static let external: String = "leaf-action-external"
}

enum LeafIcon_Nav {
  static let sidebar: String = "leaf-nav-sidebar"
  static let home: String = "leaf-nav-home"
  static let team: String = "leaf-nav-team"
  static let settings: String = "leaf-nav-settings"
  static let activity: String = "leaf-nav-activity"
  static let connections: String = "leaf-nav-connections"
  static let profile: String = "leaf-nav-profile"
  // search / filter / organization intentionally remain SF Symbols.
  // organization will be removed once the UX moves to a single-team model.
  // SF picks chosen for outline/light visual weight to match the custom
  // SVG aesthetic (avoid filled-circle variants that contrast heavily).
  static let searchSF: String = "magnifyingglass"
  static let askLeafSF: String = "sparkles"
  static let filterSF: String = "line.3.horizontal.decrease"
  static let organizationSF: String = "building.2"
}

enum LeafIcon_Comm {
  static let email: String = "leaf-comm-email"
  static let message: String = "leaf-comm-message"
  static let copy: String = "leaf-comm-copy"
  static let share: String = "leaf-comm-share"
}

enum LeafIcon_Status {
  static let success: String = "leaf-status-success"
  static let successFill: String = "leaf-status-success-fill"
  static let warning: String = "leaf-status-warning"
  static let warningFill: String = "leaf-status-warning-fill"
  static let info: String = "leaf-status-info"
}

enum LeafIcon_Object {
  static let trash: String = "leaf-object-trash"
  static let appPlaceholder: String = "leaf-object-app-placeholder"
  static let folderEmpty: String = "leaf-object-folder-empty"
  static let userError: String = "leaf-object-user-error"
}

enum LeafIcon_Metric {
  static let up: String = "leaf-metric-up"
  static let down: String = "leaf-metric-down"
  static let flat: String = "leaf-metric-flat"
}

enum LeafIcons {
  typealias brand = LeafIcon_Brand
  typealias action = LeafIcon_Action
  typealias nav = LeafIcon_Nav
  typealias comm = LeafIcon_Comm
  typealias status = LeafIcon_Status
  typealias object = LeafIcon_Object
  typealias metric = LeafIcon_Metric
}
