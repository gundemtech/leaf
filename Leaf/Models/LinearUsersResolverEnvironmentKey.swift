//
//  LinearUsersResolverEnvironmentKey.swift
//  Leaf
//
//  Track 5 / S6 T13 — SwiftUI EnvironmentKey for the LinearUsersResolver actor.
//  Actors can't conform to Observable (Observation Tracking), so the
//  `.environment(value:)` overload for @Observable doesn't apply. This
//  custom key threads the resolver through the environment as a Sendable
//  reference type for OrganizationView → SendDirectMessageSheet wiring.
//

import SwiftUI
import LeafCore

private struct LinearUsersResolverEnvironmentKey: EnvironmentKey {
    /// Stub provider returns empty user list → resolve(displayName:) always
    /// returns nil → Send sheet shows "Will create unassigned issue" notice.
    /// Production composition root overrides with the real resolver wired
    /// to LinearCorePrivate moat provider.
    @MainActor static let defaultValue: LinearUsersResolver = LinearUsersResolver(
        provider: StubLinearGraphQLProvider()
    )
}

extension EnvironmentValues {
    var linearUsersResolver: LinearUsersResolver {
        get { self[LinearUsersResolverEnvironmentKey.self] }
        set { self[LinearUsersResolverEnvironmentKey.self] = newValue }
    }
}
