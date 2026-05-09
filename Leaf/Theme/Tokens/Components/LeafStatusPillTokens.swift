//
//  LeafStatusPillTokens.swift
//  Track 2 / D1 — T3 tokens for LeafStatusPill. Surfaces capsule paddings +
//  pulse-ring geometry so downstream consumers (Header presence chip, Team grid
//  status pill) can override without forking the component.
//

import CoreGraphics

enum LeafStatusPillTokens {
    static let horizontalPadding: CGFloat = LeafSpace.sm
    static let verticalPadding:   CGFloat = LeafSpace.xxs
    static let dotSlotSize:       CGFloat = 16
    static let pulseRingSize:     CGFloat = 8
    static let pulseRingWidth:    CGFloat = 1
    static let pulseScale:        CGFloat = 2.0
    static let pulseDuration:     Double  = 1.2
}
