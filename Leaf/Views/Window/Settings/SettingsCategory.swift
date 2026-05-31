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

import Foundation

enum SettingsCategory: String, CaseIterable, Identifiable, Hashable {
  case workspace
  case sharing
  case notifications
  case data
  case general

  var id: String { rawValue }

  var title: String {
    switch self {
    case .workspace:     "Workspace"
    case .sharing:       "Sharing"
    case .notifications: "Notifications"
    case .data:          "Data"
    case .general:       "General"
    }
  }
}
