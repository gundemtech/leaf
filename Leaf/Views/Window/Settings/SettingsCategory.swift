//
//  SettingsCategory.swift
//  Settings redesign — the single long ScrollView of 13 stacked sections is
//  split into 5 categories switched via a top LeafTab strip (mirrors the
//  Activity screen's modePicker). Only the selected category's sections mount
//  at a time, so each view is a short, legible scroll.
//
//  String-raw + Hashable so the selection persists via @AppStorage
//  (RawRepresentable<String>) and satisfies LeafTab's `Hashable & Identifiable`.
//  Tab labels are intentionally short — LeafTab lays them out in a non-scrolling
//  HStack, so long strings ("Sharing & Privacy") would clip on a narrow window.
//
//  Team → Workspace Hub: `.workspace` removed — workspace-scoped sections
//  (identity, members, invites, share rules, danger zone) live on the Team
//  page now. `.sharing` keeps its rawValue (persisted selections survive)
//  but is retitled "Privacy" — only the device-wide retention section
//  remains. Stale persisted "workspace" strings decode to nil →
//  @AppStorage falls back to the declared default.
//

import Foundation

enum SettingsCategory: String, CaseIterable, Identifiable, Hashable {
  case sharing
  case notifications
  case data
  case general

  var id: String { rawValue }

  var title: String {
    switch self {
    case .sharing:       "Privacy"
    case .notifications: "Notifications"
    case .data:          "Data"
    case .general:       "General"
    }
  }
}
