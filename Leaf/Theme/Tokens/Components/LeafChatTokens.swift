//
//  LeafChatTokens.swift
//  T3 tokens for the Team hub Chats tab: two-pane split (conversation
//  list + thread), chat bubbles, composer.
//

import SwiftUI

public enum LeafChatTokens {
  /// Page cap for the two-pane Chats tab (wider than the 760pt
  /// single-column hub cap: list column + readable thread).
  public static let pageMaxWidth: CGFloat = 1040
  /// Conversation list pane (left column).
  public static let listWidth: CGFloat = 240
  public static let listRowHeight: CGFloat = 52
  public static let listAvatarSize: CGFloat = 28
  public static let rowCornerRadius: CGFloat = LeafRadius.sm
  /// Thread bubbles.
  public static let bubbleCornerRadius: CGFloat = LeafRadius.md
  public static let bubbleMaxWidth: CGFloat = 440
  public static let bubblePaddingH: CGFloat = LeafSpace.md
  public static let bubblePaddingV: CGFloat = LeafSpace.sm
  public static let bubbleSpacing: CGFloat = LeafSpace.xs
  /// Reply quote block inside a bubble / above the composer.
  public static let quoteBarWidth: CGFloat = 3
  public static let quoteCornerRadius: CGFloat = LeafRadius.sm
  /// Composer.
  public static let composerMinHeight: CGFloat = 38
  public static let composerCornerRadius: CGFloat = LeafRadius.md
}
