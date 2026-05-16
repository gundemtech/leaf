//
//  LinearUsersResolver.swift
//  LeafCore
//
//  Track 5 / S6 T9 — actor resolving Leaf member display name → Linear
//  user UUID for cross-post assignee selection.
//
//  Per A4 brainstorm (alternatives doc):
//   - Linear `UserFilter.displayName` supports only exact / contains /
//     startsWith — no native fuzzy comparator. Local matching is cheaper
//     and more flexible.
//   - Algorithm:
//       1. Lazy-fetch viewer's accessible Linear users (cached 5 min)
//       2. Exact case-insensitive displayName match
//            unique → return id
//            multiple → return nil (ambiguous — exact-tier wins over contains)
//       3. Contains fallback (case-insensitive)
//            unique → return id
//            0 or multiple → nil
//   - Caller (SendDirectMessageSheet) treats nil as "unassigned" and shows
//     inline notice. Send still proceeds.
//
//  Cache 5 min TTL — `invalidate()` for OAuth reconnect path. Injectable
//  clock for deterministic TTL tests.
//

import Foundation

public actor LinearUsersResolver {
    /// Minimal projection of a Linear user — just the fields needed for
    /// resolution + future picker UI (M14 carry-over).
    /// ADR-010: id is Linear-internal UUID (public-safe metadata),
    /// name + displayName are self-authored — OK per Section 6.
    public struct ResolvedUser: Sendable, Equatable, Hashable {
        public let id: String
        public let displayName: String
        public let name: String

        public init(id: String, displayName: String, name: String) {
            self.id = id
            self.displayName = displayName
            self.name = name
        }
    }

    private let provider: LinearGraphQLProviding
    private var cache: [ResolvedUser]?
    private var cachedAt: Date?
    private let ttl: TimeInterval
    private let clock: @Sendable () -> Date

    /// Inflight Task tracked so concurrent `resolve()` callers AWAIT the
    /// same fetch rather than enter the actor's reentry slot and duplicate
    /// the GraphQL request. See `refreshIfStale()` for full rationale.
    private var inflight: Task<[ResolvedUser], Error>?

    public init(
        provider: LinearGraphQLProviding,
        ttl: TimeInterval = 300,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.provider = provider
        self.ttl = ttl
        self.clock = clock
    }

    /// Returns Linear user.id matching the Leaf member's display_name, or
    /// nil if no unique resolution exists. See file header for algorithm.
    public func resolve(displayName: String) async throws -> String? {
        let users = try await refreshIfStale()
        let needle = displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        // Empty needle never matches — fail-safe.
        guard !needle.isEmpty else { return nil }

        // Tier 1: exact case-insensitive.
        let exact = users.filter { $0.displayName.lowercased() == needle }
        if exact.count == 1 { return exact[0].id }
        if exact.count > 1 { return nil }   // ambiguous — exact tier blocks fallback

        // Tier 2: contains fallback.
        let contains = users.filter { $0.displayName.lowercased().contains(needle) }
        if contains.count == 1 { return contains[0].id }
        return nil   // 0 or >1 — caller treats as unassigned
    }

    /// Drops cached users. Next `resolve()` re-fetches from Linear.
    /// Called by OAuth reconnect / user list refresh flows.
    public func invalidate() {
        cache = nil
        cachedAt = nil
    }

    // MARK: - Private

    /// Returns cached users if fresh, otherwise fetches + caches.
    ///
    /// Inflight coalescing — concurrent callers await the same Task rather
    /// than entering the actor reentry slot and duplicating fetches.
    /// Critical for production HTTP impl where `fetchAccessibleUsers` has
    /// 200-500ms latency and N concurrent `resolve()` calls would otherwise
    /// queue N GraphQL requests (the prior "actor serializes" comment was
    /// wrong: Swift actor reentrancy at `await` lets the second caller
    /// enter while the first is suspended on `provider.fetch…`, both then
    /// see stale cache and both fire fetches).
    private func refreshIfStale() async throws -> [ResolvedUser] {
        if let cache, let cachedAt, clock().timeIntervalSince(cachedAt) < ttl {
            return cache
        }
        // Inflight Task: second/Nth caller awaits the same fetch.
        if let inflight {
            return try await inflight.value
        }
        let task = Task { try await provider.fetchAccessibleUsers() }
        inflight = task
        defer { inflight = nil }
        let fetched = try await task.value
        cache = fetched
        cachedAt = clock()
        return fetched
    }
}
