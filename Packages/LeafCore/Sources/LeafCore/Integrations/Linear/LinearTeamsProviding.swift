//
//  LinearTeamsProviding.swift
//  LeafCore
//
//  Track 5 / S6 T11 — narrow Sendable surface used by `LinearTeamsReader`
//  to fetch the viewer's accessible Linear teams for the cross-post
//  team picker UI (Task creation target).
//
//  Why a separate protocol from `LinearGraphQLProviding`:
//   - Reader needs a different query (`viewer.teams.nodes { id name key }`)
//     than the existing users-resolution surface;
//   - Keeps the test stub tiny;
//   - Symmetric с `SlackChannelsProviding` (T11 sibling).
//
//  Production impl lives in `LeafCorePrivate` (moat). The stub returns an
//  empty list so non-LeafCorePrivate builds (CI / dev) compile.
//

import Foundation

/// Fetches the Linear teams the current viewer can create issues in.
/// Empty array is a valid response — caller (UI) shows an empty state.
public protocol LinearTeamsProviding: Sendable {
    /// Returns the viewer's accessible teams. Implementations should
    /// project the `viewer.teams { nodes { id name key } }` GraphQL slice.
    func fetchAccessibleTeams() async throws -> [LinearTeamsReader.LinearTeam]
}

/// Stub for CI / dev-without-moat builds. Returns an empty list — team
/// picker surfaces "no teams yet — re-authorize Linear" copy.
public struct StubLinearTeamsProvider: LinearTeamsProviding {
    public init() {}
    public func fetchAccessibleTeams() async throws -> [LinearTeamsReader.LinearTeam] {
        []
    }
}
