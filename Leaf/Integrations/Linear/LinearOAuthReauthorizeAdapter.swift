//
//  LinearOAuthReauthorizeAdapter.swift
//  Leaf
//
//  Track 5 / S6 T13 — adapter conforming app-target `LinearOAuthService`
//  to the LeafCore-side `LinearOAuthReauthorizing` Sendable protocol.
//  LeafCore can't import the app-target service (SwiftUI / AppKit / browser
//  opening) — this thin bridge wires the reader to the real flow.
//

import Foundation
import LeafCore

/// Wraps a `LinearOAuthService` reference and exposes the Sendable
/// `LinearOAuthReauthorizing.connect()` entry point. `@MainActor`-hop
/// happens inside `connect()` since the underlying service is @MainActor.
struct LinearOAuthReauthorizeAdapter: LinearOAuthReauthorizing {
    /// Captures a reference to the @MainActor service. The adapter itself
    /// is Sendable because `connect()` always hops to MainActor before
    /// touching the service.
    @MainActor private let service: LinearOAuthService

    @MainActor init(service: LinearOAuthService) {
        self.service = service
    }

    func connect() async {
        await service.connect()
    }
}
