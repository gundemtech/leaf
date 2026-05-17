//
//  LeafColor.swift
//  Track 2 / D1 — Tier 2 semantic colour tokens. Resolve to Asset Catalog
//  entries (light + dark variants automatic). UI code consumes only
//  LeafColor.<group>.<intent>; no direct LeafPrimitive references.
//

import SwiftUI

enum LeafColor {
    enum surface {
        static let canvas = Color("LeafSurfaceCanvas")
        static let raised = Color("LeafSurfaceRaised")
        static let inset = Color("LeafSurfaceInset")

        /// Glass surfaces — material wrapped via LeafGlass.<variant>; accent tint via LeafGlassTintAccent.
        /// `surface.glassTint` exposes the accent overlay colour for accent-tinted glass.
        static let glassTint = Color("LeafGlassTintAccent")
    }

    enum text {
        static let primary = Color("LeafTextPrimary")
        static let secondary = Color("LeafTextSecondary")
        static let tertiary = Color("LeafTextTertiary")
        static let quaternary = Color("LeafTextQuaternary")
        static let inverse = Color("LeafTextInverse")
    }

    enum accent {
        static let primary = Color("LeafAccentPrimary")
        static let subtle = Color("LeafAccentSubtle")
        static let emphasis = Color("LeafAccentEmphasis")
    }

    enum status {
        static let success = Color("LeafStatusSuccess")
        static let warning = Color("LeafStatusWarning")
        static let danger = Color("LeafStatusDanger")
        static let info = Color("LeafStatusInfo")
    }

    enum border {
        static let subtle = Color("LeafBorderSubtle")
        static let strong = Color("LeafBorderStrong")
        static let focus = Color("LeafBorderFocus")
    }
}
