//
//  LeafColor.swift
//  Track 2 / D1 — Tier 2 semantic colour tokens. Resolve to Asset Catalog
//  entries (light + dark variants automatic). UI code consumes only
//  LeafColor.<group>.<intent>; no direct LeafPrimitive references.
//

import SwiftUI

enum LeafColor {
    enum surface {
        static let canvas: Color = Color("LeafSurfaceCanvas")
        static let raised: Color = Color("LeafSurfaceRaised")
        static let inset: Color = Color("LeafSurfaceInset")

        /// Glass surfaces — material wrapped via LeafGlass.<variant>; accent tint via LeafGlassTintAccent.
        /// `surface.glassTint` exposes the accent overlay colour for accent-tinted glass.
        static let glassTint: Color = Color("LeafGlassTintAccent")
    }

    enum text {
        static let primary: Color = Color("LeafTextPrimary")
        static let secondary: Color = Color("LeafTextSecondary")
        static let tertiary: Color = Color("LeafTextTertiary")
        static let quaternary: Color = Color("LeafTextQuaternary")
        static let inverse: Color = Color("LeafTextInverse")
    }

    enum accent {
        static let primary: Color = Color("LeafAccentPrimary")
        static let subtle: Color = Color("LeafAccentSubtle")
        static let emphasis: Color = Color("LeafAccentEmphasis")
    }

    enum status {
        static let success: Color = Color("LeafStatusSuccess")
        static let warning: Color = Color("LeafStatusWarning")
        static let danger: Color = Color("LeafStatusDanger")
        static let info: Color = Color("LeafStatusInfo")
    }

    enum border {
        static let subtle: Color = Color("LeafBorderSubtle")
        static let strong: Color = Color("LeafBorderStrong")
        static let focus: Color = Color("LeafBorderFocus")
    }
}
