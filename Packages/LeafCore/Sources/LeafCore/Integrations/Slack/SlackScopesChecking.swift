//
//  SlackScopesChecking.swift
//  LeafCore
//
//  Phase Track-3 D3 — minimal scope-check protocol decoupling warm/cold
//  collectors from the SlackScopesService actor that Task 8 introduces.
//
//  Why a protocol shim:
//  - Warm/cold collectors (Tasks 12 / 14) land before the scopes service actor.
//  - Tests need a synchronous fake that does not require a Database round-trip
//    nor a running OAuth flow.
//  - Task 8 conforms the production actor to this protocol; no collector
//    code changes when the actor lands. Mirrors GitHub D2
//    `GitHubScopesChecking` precedent.
//

import Foundation

/// Decision interface for whether an OAuth scope is granted on the active
/// Slack integration. Implementations may consult cached state
/// (`integrations.scope` row in SQLCipher) or a fresh `/auth.test`-derived probe.
public protocol SlackScopesChecking: Sendable {
    /// Returns `true` iff the named scope is part of the active integration's
    /// granted scope set. Unknown / empty / disconnected integrations return
    /// `false` (caller treats as "not granted" → skip gated endpoint).
    func has(_ scope: String) async -> Bool
}
