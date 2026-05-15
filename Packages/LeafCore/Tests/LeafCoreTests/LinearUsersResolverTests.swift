//
//  LinearUsersResolverTests.swift
//  LeafCoreTests
//
//  Track 5 / S6 T9 — verifies LinearUsersResolver actor performs fuzzy
//  Leaf-member → Linear-user-id resolution per A4 brainstorm:
//    1) Exact case-insensitive displayName match → unique → return id
//    2) Contains match (case-insensitive) → unique → return id
//    3) 0 or ambiguous (multiple) → nil → caller surfaces "unassigned" note
//  Cache 5min TTL with injectable clock for deterministic TTL tests.
//

import Foundation
import Testing
@testable import LeafCore

/// Thread-safe recording mock — actor isolation gives us safe counter
/// without locks. Returns canned data; supports failure injection.
private actor MockLinearGraphQLProvider: LinearGraphQLProviding {
    private(set) var fetchCallCount = 0
    private let canned: [LinearUsersResolver.ResolvedUser]
    private let error: Error?

    init(canned: [LinearUsersResolver.ResolvedUser], error: Error? = nil) {
        self.canned = canned
        self.error = error
    }

    func fetchAccessibleUsers() async throws -> [LinearUsersResolver.ResolvedUser] {
        fetchCallCount += 1
        if let error { throw error }
        return canned
    }

    func currentCallCount() -> Int { fetchCallCount }
}

/// Helper — build ResolvedUser without verbose init in every test.
private func user(_ id: String, displayName: String, name: String? = nil) -> LinearUsersResolver.ResolvedUser {
    LinearUsersResolver.ResolvedUser(id: id, displayName: displayName, name: name ?? displayName)
}

@Suite("LinearUsersResolver")
struct LinearUsersResolverTests {
    // MARK: - Resolution algorithm

    @Test("exact case-sensitive match → unique id")
    func exactCaseSensitive() async throws {
        let mock = MockLinearGraphQLProvider(canned: [user("u1", displayName: "Dmitrii")])
        let resolver = LinearUsersResolver(provider: mock)
        let id = try await resolver.resolve(displayName: "Dmitrii")
        #expect(id == "u1")
    }

    @Test("exact case-insensitive match (lowercase needle vs PascalCase haystack)")
    func exactCaseInsensitive() async throws {
        let mock = MockLinearGraphQLProvider(canned: [user("u1", displayName: "Dmitrii")])
        let resolver = LinearUsersResolver(provider: mock)
        let id = try await resolver.resolve(displayName: "dmitrii")
        #expect(id == "u1")
    }

    @Test("contains fallback finds unique substring match")
    func containsFallbackUnique() async throws {
        let mock = MockLinearGraphQLProvider(canned: [
            user("u1", displayName: "Dmitrii"),
            user("u2", displayName: "Dima D.")
        ])
        let resolver = LinearUsersResolver(provider: mock)
        let id = try await resolver.resolve(displayName: "Dima")
        #expect(id == "u2")
    }

    @Test("contains fallback — multiple matches → nil (ambiguous)")
    func containsFallbackAmbiguous() async throws {
        let mock = MockLinearGraphQLProvider(canned: [
            user("u1", displayName: "Dima"),
            user("u2", displayName: "Dmitrii")
        ])
        let resolver = LinearUsersResolver(provider: mock)
        let id = try await resolver.resolve(displayName: "D")
        #expect(id == nil)
    }

    @Test("no matches → nil")
    func noMatch() async throws {
        let mock = MockLinearGraphQLProvider(canned: [user("u1", displayName: "Dmitrii")])
        let resolver = LinearUsersResolver(provider: mock)
        let id = try await resolver.resolve(displayName: "Xavier")
        #expect(id == nil)
    }

    @Test("empty cache (provider returned []) → nil")
    func emptyCache() async throws {
        let mock = MockLinearGraphQLProvider(canned: [])
        let resolver = LinearUsersResolver(provider: mock)
        let id = try await resolver.resolve(displayName: "Anyone")
        #expect(id == nil)
    }

    @Test("two exact matches → nil (exact ambiguity beats contains)")
    func exactAmbiguityWinsOverContains() async throws {
        // If two users have identical displayName, resolver MUST return nil
        // even though contains-pass would also match. Exact ambiguity is a
        // first-class signal that resolver cannot disambiguate.
        let mock = MockLinearGraphQLProvider(canned: [
            user("u1", displayName: "Dmitrii"),
            user("u2", displayName: "Dmitrii")
        ])
        let resolver = LinearUsersResolver(provider: mock)
        let id = try await resolver.resolve(displayName: "Dmitrii")
        #expect(id == nil)
    }

    // MARK: - Cache TTL

    @Test("second resolve within TTL does not re-fetch")
    func cachedWithinTTL() async throws {
        let mock = MockLinearGraphQLProvider(canned: [user("u1", displayName: "A")])
        let resolver = LinearUsersResolver(provider: mock)
        _ = try await resolver.resolve(displayName: "A")
        _ = try await resolver.resolve(displayName: "A")
        let count = await mock.currentCallCount()
        #expect(count == 1)
    }

    @Test("resolve after TTL expiry refetches")
    func staleAfterTTL() async throws {
        // Injectable clock: start at t0, advance past 5min for second call.
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let clockBox = ClockBox(now: t0)
        let mock = MockLinearGraphQLProvider(canned: [user("u1", displayName: "A")])
        let resolver = LinearUsersResolver(
            provider: mock,
            ttl: 300,
            clock: { clockBox.read() }
        )
        _ = try await resolver.resolve(displayName: "A")
        clockBox.advance(by: 301) // past TTL
        _ = try await resolver.resolve(displayName: "A")
        let count = await mock.currentCallCount()
        #expect(count == 2)
    }

    @Test("invalidate() forces next call to refetch")
    func invalidateForcesRefetch() async throws {
        let mock = MockLinearGraphQLProvider(canned: [user("u1", displayName: "A")])
        let resolver = LinearUsersResolver(provider: mock)
        _ = try await resolver.resolve(displayName: "A")
        await resolver.invalidate()
        _ = try await resolver.resolve(displayName: "A")
        let count = await mock.currentCallCount()
        #expect(count == 2)
    }

    // MARK: - Concurrency

    @Test("concurrent resolve calls do not double-fetch (actor coalesces)")
    func concurrentResolveCoalesces() async throws {
        let mock = MockLinearGraphQLProvider(canned: [user("u1", displayName: "A")])
        let resolver = LinearUsersResolver(provider: mock)
        // Actor reentrancy: many parallel calls but actor serializes;
        // first call populates cache, subsequent reads hit it.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    _ = try? await resolver.resolve(displayName: "A")
                }
            }
        }
        let count = await mock.currentCallCount()
        #expect(count == 1)
    }

    // MARK: - Error propagation

    @Test("provider throws → resolve re-throws")
    func providerError() async {
        struct E: Error {}
        let mock = MockLinearGraphQLProvider(canned: [], error: E())
        let resolver = LinearUsersResolver(provider: mock)
        await #expect(throws: E.self) {
            try await resolver.resolve(displayName: "anything")
        }
    }
}

// MARK: - Test helpers

/// Mutable date holder for tests advancing simulated clock.
/// Using a reference-typed class with NSLock keeps it Sendable-safe
/// for the @escaping clock closure (which is @Sendable).
private final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(now: Date) {
        self.current = now
    }

    func read() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}
