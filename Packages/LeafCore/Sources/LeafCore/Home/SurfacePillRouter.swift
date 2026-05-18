//
//  SurfacePillRouter.swift
//  Track 8 / Phase 8.3 — Maps `SurfacePill.id` strings emitted by
//  `DerivedInsights.todayMetrics(now:)` to the matching navigation route.
//  Capture surfaces (`HomeSurface`) route via `RouteCoordinator.pushHome(_:)`;
//  Layer B providers (`LayerBProvider`) route via
//  `RouteCoordinator.pushHomeLayerBProvider(_:)`. Lives in LeafCore so the
//  resolution is testable without the app target.
//

import Foundation

public enum SurfacePillRoute: Equatable, Hashable, Sendable {
    case homeSurface(HomeSurface)
    case layerBProvider(LayerBProvider)
}

public enum SurfacePillRouter {
    /// Returns the navigation route for a TODAY pill, or `nil` if the pill ID
    /// does not match a known surface. Callers must leave `nil`-route pills
    /// non-tappable rather than crashing.
    public static func route(forPillID id: String) -> SurfacePillRoute? {
        if let surface = HomeSurface(rawValue: id) {
            return .homeSurface(surface)
        }
        if let provider = LayerBProvider(rawValue: id) {
            return .layerBProvider(provider)
        }
        return nil
    }
}
