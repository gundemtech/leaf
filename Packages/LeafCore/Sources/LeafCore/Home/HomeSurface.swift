//
//  HomeSurface.swift
//  Track 7 — Home dashboard surface identity. Pure value type so it can be
//  used as a `NavigationStack` destination, a dictionary key, and a
//  CaseIterable driver for the Home Surfaces section. `SurfaceCatalog.all`
//  is the single source of truth for render order (capture-volume heuristic
//  per spec §3); changing it changes the dashboard.
//

import Foundation

public enum HomeSurface: String, CaseIterable, Hashable, Codable, Sendable, Identifiable {
    case claudeCode
    case xcode
    case ides
    case browsers
    case zoom
    case calendar

    public var id: String { rawValue }

    /// English display name. UI consumers must render via
    /// `Text(LocalizedStringKey(localizationKey))` — `displayName` is the
    /// fallback / accessibility label only. Track 7 P1 ships English literals;
    /// `Localizable.strings` entries land in P11 polish.
    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .xcode: "Xcode"
        case .ides: "IDEs"
        case .browsers: "Browsers"
        case .zoom: "Zoom"
        case .calendar: "Calendar"
        }
    }

    public var localizationKey: String {
        "home.surface.\(rawValue).name"
    }
}

public enum SurfaceCatalog {
    /// Canonical ordering (capture-volume heuristic per spec §3 / §A5).
    /// Enabled surfaces render first as full cards; disabled surfaces
    /// render below as compact rows. Within each partition, ordering
    /// follows this array.
    public static let all: [HomeSurface] = [
        .claudeCode,  // 1 — highest volume (AI coding flow)
        .xcode,  // 2 — primary dev IDE on macOS
        .ides,  // 3 — secondary dev IDEs
        .browsers,  // 4 — research / docs
        .zoom,  // 5 — async-light
        .calendar,  // 6 — atomic state events
    ]
}
