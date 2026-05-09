//
//  LeafProgressTokens.swift
//  Track 2 / D1 — T3 tokens for LeafProgress. Style = linear | circular(size).
//  Linear bar height + circular size table live here so progress geometry
//  stays consistent across surfaces (sync, upload, OAuth flows).
//

import CoreGraphics

enum LeafProgressTokens {
    enum CircularSize {
        case sm, md, lg
        var pt: CGFloat {
            switch self {
            case .sm: 16
            case .md: 24
            case .lg: 36
            }
        }
    }

    enum Style {
        case linear
        case circular(CircularSize)
    }

    static let linearHeight: CGFloat = 4
}
