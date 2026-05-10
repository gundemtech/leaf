//
//  LeafType.swift
//  Track 2 / D1 — Tier 2 typography tokens. SF Pro Display/Text/Mono.
//  Consumers use .font(LeafType.<group>.<size>); never raw .system(size:weight:).
//

import SwiftUI

enum LeafType {
    enum display {
        static let large    = Font.system(size: 64, weight: .semibold, design: .default)
            .leafTracking(-0.02)
        static let regular  = Font.system(size: 48, weight: .semibold, design: .default)
            .leafTracking(-0.02)
    }

    enum title {
        static let large   = Font.system(size: 28, weight: .semibold, design: .default)
            .leafTracking(-0.01)
        static let medium  = Font.system(size: 22, weight: .semibold, design: .default)
        static let small   = Font.system(size: 17, weight: .semibold, design: .default)
    }

    enum body {
        static let large   = Font.system(size: 17, weight: .regular,  design: .default)
        static let regular = Font.system(size: 15, weight: .regular,  design: .default)
        static let small   = Font.system(size: 13, weight: .regular,  design: .default)
    }

    static let caption = Font.system(size: 12, weight: .regular, design: .default)

    /// Section labels — uppercase + tracking applied at the Text level via `Text.leafSectionLabel()`.
    static let label = Font.system(size: 11, weight: .medium, design: .default)

    enum mono {
        static let regular = Font.system(size: 14, weight: .regular,  design: .monospaced)
        static let small   = Font.system(size: 12, weight: .regular,  design: .monospaced)
        /// Track 2 / D3 — large monospaced display for OAuth user codes (GitHub
        /// device flow `.awaitingAuthorization` state). Single consumer in D3;
        /// surface as T2 token so we don't sprinkle raw Font.system(size:28)
        /// across views. No T3 component-token layer — single use-site.
        static let large   = Font.system(size: 28, weight: .semibold, design: .monospaced)
    }
}

private extension Font {
    /// `.tracking(...)` is iOS/macOS 16+. Tracking is in points relative to em-width
    /// (Apple uses points, not em). For label tracking we rely on `Text.tracking()` modifier;
    /// here we keep the Font value and apply tracking at the Text level when needed via
    /// `.tracking(0.04 * fontSize)` rule of thumb. For display/title we leverage
    /// `.tracking(...)` inline at consumer if needed.
    func leafTracking(_ ems: CGFloat) -> Font {
        // Font has no native tracking; tracking is applied via Text modifier.
        // Returning self preserves call-site pattern; consumers wrap Text with .tracking() per spec.
        return self
    }
}

extension Text {
    /// Section label style — uppercase + 0.04em tracking (≈0.44pt for 11pt).
    /// Returns `some View` because `.textCase` produces a View, not a Text.
    /// Canonical section-label text helper across the app (Track 2 / D4 retirement
    /// completed Snapshot Replacement migration; old palette helper removed).
    func leafSectionLabel() -> some View {
        self.font(LeafType.label)
            .tracking(0.44)
            .textCase(.uppercase)
    }

    /// Display-large tracking helper — applies -0.02em (≈-1.28pt for 64pt).
    func leafDisplayTracking() -> Text {
        self.tracking(-1.28)
    }
}
