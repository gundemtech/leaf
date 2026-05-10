//
//  LeafDot.swift
//  Track 2 / D1 — Atom A2. Filled circle for presence indicator / provider dot.
//  6 tones (accent / success / warning / danger / info / muted) × 3 sizes (sm/md/lg).
//

import SwiftUI

enum LeafDotTone {
    case accent
    case success, warning, danger, info
    case muted

    var color: Color {
        switch self {
        case .accent:  LeafColor.accent.primary
        case .success: LeafColor.status.success
        case .warning: LeafColor.status.warning
        case .danger:  LeafColor.status.danger
        case .info:    LeafColor.status.info
        case .muted:   LeafColor.text.tertiary
        }
    }
}

enum LeafDotSize {
    case sm, md, lg
    var pt: CGFloat {
        switch self {
        case .sm: 6
        case .md: 8
        case .lg: 12
        }
    }
}

struct LeafDot: View {
    var tone: LeafDotTone = .accent
    var size: LeafDotSize = .md

    var body: some View {
        Circle()
            .fill(tone.color)
            .frame(width: size.pt, height: size.pt)
    }
}
