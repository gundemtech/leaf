//  RouteCoordinator.swift
//  Track 7 P1 — environment-injected router. Holds a `pendingSettingsTarget`
//  that `WindowSettingsView` consumes via ScrollViewReader on appear /
//  on-change. Holds a `homePath: NavigationPath` so HomeView can drive a
//  NavigationStack from outside the view (lets Recent Sessions / Today /
//  banners push a detail destination without nesting NavigationLink calls).

import AppKit
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

    // IV.A.1 — Track-7 push* methods (HomeSurface/WorkStateRoute/LayerBProvider)
    // dropped: integration spec §4 skips Track-7 P1-P5 drill-down surfaces.
    // pushHome / pushHomeWorkState / pushHomeLayerBProvider re-add in IV.A.2
    // only if T7 HomeContent extraction needs them (likely no — Track-10 zones
    // don't nest NavigationStack drill-downs).

    func popHome() {
        guard !homePath.isEmpty else { return }
        homePath.removeLast()
    }

    func consumePendingSettingsTarget() -> (section: SettingsSection, sub: SettingsSubsection?)? {
        let snapshot = pendingSettingsTarget
        pendingSettingsTarget = nil
        return snapshot
    }

    /// Track-10 T2 — opens an external URL via `NSWorkspace`. Centralized helper so
    /// view layer doesn't import AppKit just to fire a browser open. Reused by
    /// RESUME hero "Linear" + "Diff with main" CTAs; ready for T5 SINCE timeline
    /// row-tap reuse.
    func openExternalURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
