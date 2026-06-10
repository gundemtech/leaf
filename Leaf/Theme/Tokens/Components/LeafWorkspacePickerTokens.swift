//
//  LeafWorkspacePickerTokens.swift
//  T3 tokens for LeafWorkspacePicker — sidebar bottom workspace picker:
//  compact trigger row + popover list. Row metrics carried over from the
//  retired LeafWorkspaceSwitcherTokens (Track 5 / S7) so the popover rows
//  render identically to the old inline list.
//

import SwiftUI

public enum LeafWorkspacePickerTokens {
  public static let rowHeight: CGFloat = 32
  public static let avatarSize: CGFloat = 16
  public static let activeIconSize: CGFloat = 14
  public static let interRowSpacing: CGFloat = LeafSpace.xs
  public static let dividerOpacity: Double = 0.3
  public static let sectionPadding: CGFloat = LeafSpace.md
  public static let triggerHeight: CGFloat = 36
  public static let triggerCornerRadius: CGFloat = LeafRadius.md
  public static let popoverWidth: CGFloat = 240
  /// Popover list scrolls past this height instead of growing unbounded.
  public static let maxListHeight: CGFloat = 280
}
