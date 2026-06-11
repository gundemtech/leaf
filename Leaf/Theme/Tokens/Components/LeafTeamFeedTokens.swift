//
//  LeafTeamFeedTokens.swift
//  Team UI polish — feed column + chat-style metrics.
//

import SwiftUI

enum LeafTeamFeedTokens {
  /// Content column cap — the whole Team page column (header + filters +
  /// feed) centers at this width on wide windows so timestamps don't drift
  /// far from the text they belong to.
  static let maxContentWidth: CGFloat = 760
  /// A DM bubble never exceeds this — keeps line length readable.
  static let bubbleMaxWidth: CGFloat = 480
  /// Member-strip avatar horizontal overlap.
  static let avatarOverlap: CGFloat = 6
  /// Max avatars before collapsing into a "+N" chip.
  static let memberStripVisibleCap: Int = 8
}
