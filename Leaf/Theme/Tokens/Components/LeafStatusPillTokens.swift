//
//  LeafStatusPillTokens.swift
//  Track 2 / D1 — T3 tokens for LeafStatusPill. Surfaces capsule paddings +
//  pulse-ring geometry so downstream consumers (Header presence chip, Team grid
//  status pill) can override without forking the component.
//

import CoreGraphics
import Foundation

enum LeafStatusPillTokens {
    static let horizontalPadding: CGFloat = LeafSpace.sm
    static let verticalPadding:   CGFloat = LeafSpace.xxs
    static let dotSlotSize:       CGFloat = 16
    static let pulseRingSize:     CGFloat = 8
    static let pulseRingWidth:    CGFloat = 1
    static let pulseScale:        CGFloat = 2.0
    static let pulseDuration:     Double  = 1.2

    /// Track 2 / D2 — boundary beyond which the most-recent session is considered "stale";
    /// status pill flips active → idle. Default 60s balances the "user left"
    /// signal against flicker prevention. Phase 5.4 reuses the same token for
    /// presence_outgoing snapshot derive (single source of truth).
    static let activeThresholdSeconds: TimeInterval = 60
}
