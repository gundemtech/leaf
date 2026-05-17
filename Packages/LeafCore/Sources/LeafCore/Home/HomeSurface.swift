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

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .xcode:      "Xcode"
        case .ides:       "IDEs"
        case .browsers:   "Browsers"
        case .zoom:       "Zoom"
        case .calendar:   "Calendar"
        }
    }

    public var localizationKey: String {
        "home.surface.\(rawValue).name"
    }
}

public enum SurfaceCatalog {
    public static let all: [HomeSurface] = [
        .claudeCode, .xcode, .ides, .browsers, .zoom, .calendar
    ]
}
