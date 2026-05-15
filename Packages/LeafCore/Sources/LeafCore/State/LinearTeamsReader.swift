//
//  LinearTeamsReader.swift
//  LeafCore
//
//  Track 5 / S6 T11 — @MainActor @Observable wrapper backing the Linear
//  team picker in ChannelsPickerSection. Symmetric to SlackChannelsReader:
//  fetch-on-connect + lazy 5-minute stale-while-revalidate cache.
//
//  Production impl of `LinearTeamsProviding` lives in `LeafCorePrivate`
//  and projects `viewer.teams { nodes { id name key } }` GraphQL slice.
//

import Foundation
import Observation

@MainActor
@Observable
public final class LinearTeamsReader {
    /// Linear team UUID + display name + project key (e.g. "LEA"). The
    /// `key` is shown in the team picker as a short identifier
    /// ("Leaf — LEA") to disambiguate teams with similar names.
    public struct LinearTeam: Identifiable, Sendable, Equatable, Hashable {
        public let id: String   // Linear team UUID
        public let name: String
        public let key: String  // e.g. "LEA"

        public init(id: String, name: String, key: String) {
            self.id = id
            self.name = name
            self.key = key
        }
    }

    public private(set) var teams: [LinearTeam] = []
    public private(set) var lastFetchedAt: Date?
    public private(set) var isLoading: Bool = false
    public private(set) var error: String?

    private let provider: LinearTeamsProviding
    private let ttl: TimeInterval
    private let clock: @Sendable () -> Date

    public init(
        provider: LinearTeamsProviding,
        ttl: TimeInterval = 300,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.provider = provider
        self.ttl = ttl
        self.clock = clock
    }

    /// Called after OAuth success — warms the cache so the first Send
    /// sheet open doesn't spin.
    public func refreshOnConnect() async {
        await refresh()
    }

    /// Called from the Send sheet `.task` modifier. No-op if a successful
    /// fetch landed less than `ttl` ago.
    public func refreshIfStale() async {
        if let lastFetchedAt, clock().timeIntervalSince(lastFetchedAt) < ttl {
            return
        }
        await refresh()
    }

    private func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await provider.fetchAccessibleTeams()
            teams = fetched
            lastFetchedAt = clock()
            error = nil
        } catch {
            self.error = error.localizedDescription
            // Preserve previously-fetched `teams` — see SlackChannelsReader
            // header for rationale.
        }
    }
}
