//
//  LayerBProvider.swift
//  Track 7 P4 — Layer B drill-down route discriminator. Parallel to
//  HomeSurface (which is local-capture only). Each case routes to its own
//  detail screen via RouteCoordinator.pushHomeLayerBProvider(_:) +
//  HomeView's `.navigationDestination(for: LayerBProvider.self)`.
//

import Foundation

public enum LayerBProvider: String, CaseIterable, Hashable, Codable, Sendable, Identifiable {
    case linear
    case github
    case slack

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .linear: "Linear"
        case .github: "GitHub"
        case .slack:  "Slack"
        }
    }
}
