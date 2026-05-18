//  RouteCoordinator.swift
//  Track 7 P1 — environment-injected router. Holds a `pendingSettingsTarget`
//  that `WindowSettingsView` consumes via ScrollViewReader on appear /
//  on-change. Holds a `homePath: NavigationPath` so HomeView can drive a
//  NavigationStack from outside the view (lets Recent Sessions / Today /
//  banners push a detail destination without nesting NavigationLink calls).

import Foundation
import LeafCore
import Observation
import SwiftUI

@MainActor
@Observable
final class RouteCoordinator {
    /// Section + optional sub-anchor that WindowSettingsView should scroll
    /// to. Cleared after consumption.
    var pendingSettingsTarget: (section: SettingsSection, sub: SettingsSubsection?)? = nil

    /// Drives the Home pane's NavigationStack. SurfaceCard taps push a
    /// HomeSurface destination; WorkStateCard etc. would push their own
    /// destination types in P7+.
    var homePath = NavigationPath()

    func route(_ destination: AppRoute, windowState: WindowState) {
        switch destination {
        case .settings(let section, let sub):
            pendingSettingsTarget = (section, sub)
            windowState.section = .settings
        case .connections:
            windowState.section = .connections
        }
    }

    func pushHome(_ surface: HomeSurface) {
        homePath.append(surface)
    }

    /// Track 7 P3 — push the Work State detail destination onto the Home
    /// NavigationStack. Separate from `pushHome(_:HomeSurface)` because
    /// Work State is not a HomeSurface (no enable toggle, always on).
    func pushHomeWorkState() {
        homePath.append(WorkStateRoute())
    }

    func popHome() {
        guard !homePath.isEmpty else { return }
        homePath.removeLast()
    }

    /// Pushes a Layer B provider drill-down destination onto homePath.
    /// Track-7 P4: parallel к pushHome(_:HomeSurface) — LayerBProvider —
    /// отдельный route discriminator (Layer B = provider integrations,
    /// не capture surfaces).
    func pushHomeLayerBProvider(_ provider: LayerBProvider) {
        homePath.append(provider)
    }

    func consumePendingSettingsTarget() -> (section: SettingsSection, sub: SettingsSubsection?)? {
        let snapshot = pendingSettingsTarget
        pendingSettingsTarget = nil
        return snapshot
    }
}
