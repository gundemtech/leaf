//
//  LeafMessageCardTokens.swift
//  Track 5 / S7 B.8 — T3 tokens for LeafMessageCard.
//  Direct-message card: sender avatar + header + body + attachment embed +
//  cross-post badges + read receipt + hover-reveal action bar.
//

import SwiftUI

enum LeafMessageCardTokens {
    /// Inner padding of the raised card container.
    static let cardPadding: CGFloat = LeafSpace.md

    /// Width / height of the sender avatar.
    static let avatarSize: CGFloat = 32

    /// Point size of the kind indicator icon (handoff / task / ping).
    static let kindIconSize: CGFloat = 16

    /// Max body text lines before truncation with "…".
    static let bodyLineLimit: Int = 6

    /// Vertical gap between header and body text.
    static let bodySpacing: CGFloat = LeafSpace.xs

    /// Easing applied when the hover-reveal action bar appears / disappears.
    static let actionsRevealAnimation: Animation = .easeInOut(duration: 0.15)

    /// Time the card must stay visible before `onAppear` fires (nanoseconds).
    /// 1 500 ms = 1_500_000_000 ns.
    static let autoReadThresholdMs: UInt64 = 1_500

    /// Leading (inbound) or trailing (outbound) inset applied on the opposite
    /// side of the card to visually indent the message.
    static let outboundAlignmentPad: CGFloat = LeafSpace.xl

    /// Max lines for the sender display name before truncation.
    static let senderNameLineLimit: Int = 1

    /// Bubble corner radius (chat-style restyle).
    static let bubbleRadius: CGFloat = LeafRadius.md

    /// Header avatar (chat scale — smaller than the legacy 32 pt card avatar).
    static let headerAvatarSize: CGFloat = 24

    /// Hover action bar floats above the bubble's top edge by this offset so
    /// it never covers the header timestamp (legacy overlap glitch).
    static let actionBarYOffset: CGFloat = -28
}
