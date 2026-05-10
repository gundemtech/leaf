//
//  LeafToggleTokens.swift
//  Track 2 / D1 — T3 tokens for LeafToggle. macOS native switch is fixed-size,
//  so Size enum currently exposes md only — placeholder kept for future scaling
//  (sm/lg) once we ship a custom track.
//

import CoreGraphics

enum LeafToggleTokens {
    enum Size {
        case md

        var trackWidth: CGFloat { 36 }
        var trackHeight: CGFloat { 22 }
    }
}
