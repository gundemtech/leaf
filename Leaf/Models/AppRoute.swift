//  AppRoute.swift
//  Track 7 P1 — coordinator route destinations. Each Track-7 SurfaceRow
//  `[Enable]` / `[Connect]` button emits an AppRoute via RouteCoordinator.
//  Today's surface area is intentionally narrow (just Settings deep-links
//  + the OAuth connect screen). Detail-screen pushes are NavigationStack-
//  internal and do NOT go through AppRoute.

import Foundation

enum AppRoute: Hashable, Sendable {
    /// Switch to Settings tab and scroll to the named section.
    case settings(section: SettingsSection, sub: SettingsSubsection? = nil)
    /// Switch to Connections tab (existing tab, used by Calendar Connect).
    case connections
}

/// Maps 1:1 to the sub-section views inside `WindowSettingsView`.
enum SettingsSection: String, Hashable, Sendable {
    case background
    case folders
    case localApps
    case systemObservers
    case aiTools
    case browserAllowList
    case advanced
    case updates
    case privacy
}

/// Fine-grained intra-section anchor. Optional — used to scroll past the
/// section's own header to a specific row (e.g. Local Apps → Xcode row in P2).
enum SettingsSubsection: String, Hashable, Sendable {
    case claudeCode
    case xcode
    case zoom
    case ides
    case browsers
}
