//
//  GitHubScopesChecking.swift
//  LeafCore
//
//  Phase Track-3 D2 — minimal scope-check protocol decoupling warm/cold
//  collectors from the GitHubScopesService actor that Task 12 will introduce.
//
//  Why a protocol shim:
//  - Warm/cold collectors land before the scopes service actor (Tasks 8 / 10).
//  - Tests need a synchronous fake that does not require a Database round-trip
//    nor a running OAuth flow.
//  - Task 12 conforms the production actor to this protocol; no collector
//    code changes when the actor lands.
//

import Foundation

/// Decision interface for whether an OAuth scope is granted on the active
/// GitHub integration. Implementations may consult cached state (`integrations.scope`
/// row in SQLCipher) or a fresh `GET /user` `X-OAuth-Scopes` probe.
public protocol GitHubScopesChecking: Sendable {
    /// Returns `true` iff the named scope is part of the active integration's
    /// granted scope set. Unknown / empty / disconnected integrations return
    /// `false` (caller treats as "not granted" → skip gated endpoint).
    func has(_ scope: String) async -> Bool
}
