//
//  LinearTeamsReaderTests.swift
//  LeafCoreTests
//
//  Track 5 / S6 T11 — verifies LinearTeamsReader fetch-on-connect + lazy
//  5min stale-while-revalidate cache. Symmetric to SlackChannelsReaderTests.
//

import Foundation
import Testing
@testable import LeafCore

@MainActor
@Suite("LinearTeamsReader")
struct LinearTeamsReaderTests {

    // MARK: - Initial state

    @Test("initial state — teams empty, lastFetchedAt nil, isLoading false, error nil")
    func initialState() async {
        let mock = MockLinearTeamsProvider(canned: [])
        let reader = LinearTeamsReader(provider: mock)
        #expect(reader.teams.isEmpty)
        #expect(reader.lastFetchedAt == nil)
        #expect(reader.isLoading == false)
        #expect(reader.error == nil)
        let count = await mock.currentCallCount()
        #expect(count == 0)
    }

    // MARK: - refreshOnConnect

    @Test("refreshOnConnect populates teams + stamps lastFetchedAt")
    func refreshOnConnectPopulates() async {
        let canned = [
            LinearTeamsReader.LinearTeam(id: "t1", name: "Engineering", key: "ENG"),
            LinearTeamsReader.LinearTeam(id: "t2", name: "Leaf",        key: "LEA")
        ]
        let mock = MockLinearTeamsProvider(canned: canned)
        let reader = LinearTeamsReader(provider: mock)
        await reader.refreshOnConnect()
        #expect(reader.teams == canned)
        #expect(reader.lastFetchedAt != nil)
        #expect(reader.isLoading == false)
        #expect(reader.error == nil)
        let count = await mock.currentCallCount()
        #expect(count == 1)
    }

    // MARK: - refreshIfStale within TTL

    @Test("refreshIfStale within TTL is a no-op")
    func refreshIfStaleWithinTTL() async {
        let canned = [LinearTeamsReader.LinearTeam(id: "t1", name: "Engineering", key: "ENG")]
        let mock = MockLinearTeamsProvider(canned: canned)
        let reader = LinearTeamsReader(provider: mock, ttl: 300, clock: { Date() })
        await reader.refreshOnConnect()
        await reader.refreshIfStale()
        let count = await mock.currentCallCount()
        #expect(count == 1)
    }

    // MARK: - refreshIfStale past TTL

    @Test("refreshIfStale after TTL refetches")
    func refreshIfStaleAfterTTL() async {
        let canned = [LinearTeamsReader.LinearTeam(id: "t1", name: "Engineering", key: "ENG")]
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let clockBoxRef = TeamsClockBox(now: t0)
        let mock = MockLinearTeamsProvider(canned: canned)
        let reader = LinearTeamsReader(
            provider: mock,
            ttl: 300,
            clock: { clockBoxRef.read() }
        )
        await reader.refreshOnConnect()
        clockBoxRef.advance(by: 301)
        await reader.refreshIfStale()
        let count = await mock.currentCallCount()
        #expect(count == 2)
    }

    // MARK: - Provider error

    @Test("provider error → error field populated, teams unchanged")
    func providerError() async {
        struct E: LocalizedError {
            var errorDescription: String? { "graphql 500" }
        }
        let failingMock = MockLinearTeamsProvider(canned: [], error: E())
        let reader = LinearTeamsReader(provider: failingMock)
        await reader.refreshOnConnect()
        #expect(reader.error != nil)
        #expect(reader.error?.contains("graphql 500") == true)
        #expect(reader.teams.isEmpty)
    }

    // MARK: - Concurrent refresh

    @Test("concurrent refresh calls do not double-fetch (isLoading guard)")
    func concurrentRefreshNoDoubleFetch() async {
        let canned = [LinearTeamsReader.LinearTeam(id: "t1", name: "Engineering", key: "ENG")]
        let mock = SlowMockLinearTeamsProvider(canned: canned, delayMs: 50)
        let reader = LinearTeamsReader(provider: mock, ttl: 300, clock: { Date() })
        async let a: Void = reader.refreshOnConnect()
        async let b: Void = reader.refreshOnConnect()
        _ = await (a, b)
        let count = await mock.currentCallCount()
        #expect(count == 1)
    }
}

// MARK: - Test helpers

private actor MockLinearTeamsProvider: LinearTeamsProviding {
    private(set) var fetchCallCount = 0
    private let canned: [LinearTeamsReader.LinearTeam]
    private let error: Error?

    init(canned: [LinearTeamsReader.LinearTeam], error: Error? = nil) {
        self.canned = canned
        self.error = error
    }

    func fetchAccessibleTeams() async throws -> [LinearTeamsReader.LinearTeam] {
        fetchCallCount += 1
        if let error { throw error }
        return canned
    }

    func currentCallCount() -> Int { fetchCallCount }
}

private actor SlowMockLinearTeamsProvider: LinearTeamsProviding {
    private(set) var fetchCallCount = 0
    private let canned: [LinearTeamsReader.LinearTeam]
    private let delayMs: UInt64

    init(canned: [LinearTeamsReader.LinearTeam], delayMs: UInt64) {
        self.canned = canned
        self.delayMs = delayMs
    }

    func fetchAccessibleTeams() async throws -> [LinearTeamsReader.LinearTeam] {
        fetchCallCount += 1
        try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
        return canned
    }

    func currentCallCount() -> Int { fetchCallCount }
}

private final class TeamsClockBox: @unchecked Sendable {
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
