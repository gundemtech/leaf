//
//  LinearScopesChecking.swift
//  LeafCore
//
//  Track 5 / S6 T5 — minimal scope-check protocol decoupling cross-post UI
//  from the LinearScopesService actor. Mirror of SlackScopesChecking pattern
//  (Track 3 D2 GitHub D2/D3 Slack precedent).
//

import Foundation

/// Decision interface for whether an OAuth scope is granted on the active
/// Linear integration. Implementations consult cached `integrations.scope`
/// row in SQLCipher; unknown / empty / disconnected integrations return
/// `false` (caller treats as "not granted" → surface re-auth banner).
public protocol LinearScopesChecking: Sendable {
    /// Returns `true` iff the named scope is part of the active integration's
    /// granted scope set.
    func has(_ scope: String) async -> Bool
}
