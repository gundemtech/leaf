//
//  LeafWorkspacePickerTokens.swift
//  T3 tokens for LeafWorkspacePicker — sidebar bottom card: workspace
//  picker trigger row + profile row, and the popover list the trigger
//  opens. Replaces the retired LeafWorkspaceSwitcherTokens (Track 5 / S7).
//

import SwiftUI

public enum LeafWorkspacePickerTokens {
  /// Popover workspace rows.
  public static let rowHeight: CGFloat = 34
  /// Square workspace mark inside popover rows.
  public static let markSize: CGFloat = 20
  /// Square workspace mark / profile avatar on the bottom-card rows.
  public static let triggerMarkSize: CGFloat = 22
  public static let triggerHeight: CGFloat = 38
  public static let markCornerRadius: CGFloat = LeafRadius.sm
  public static let rowCornerRadius: CGFloat = LeafRadius.sm
  public static let cardCornerRadius: CGFloat = LeafRadius.md
  public static let interRowSpacing: CGFloat = LeafSpace.xxs
  public static let dividerOpacity: Double = 0.3
  public static let sectionPadding: CGFloat = LeafSpace.sm
  public static let popoverWidth: CGFloat = 260
  /// Vertical gap between the dropdown's bottom edge and the trigger top.
  public static let dropdownGap: CGFloat = LeafSpace.sm
  /// Popover list scrolls past this height instead of growing unbounded.
  public static let maxListHeight: CGFloat = 320
}
