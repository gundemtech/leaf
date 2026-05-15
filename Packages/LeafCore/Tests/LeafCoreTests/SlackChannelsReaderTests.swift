//
//  SlackChannelsReaderTests.swift
//  LeafCoreTests
//
//  Track 5 / S6 T11 — verifies SlackChannelsReader fetch-on-connect +
//  lazy 5min stale-while-revalidate cache. Mock provider records call
//  count for TTL + concurrency assertions. Injectable clock for
//  deterministic TTL tests.
//
//  Reader is @MainActor — tests await on MainActor explicitly so the
//  Swift 6 actor-hopping is observable.
//

import Foundation
import Testing
@testable import LeafCore

@MainActor
private func makeReader(
    canned: [SlackChannelsReader.SlackChannel] = [],
    error: Error? = nil,
    ttl: TimeInterval = 300,
    clockBox: ClockBox? = nil
) -> (SlackChannelsReader, MockSlackChannelsProvider) {
    let mock = MockSlackChannelsProvider(canned: canned, error: error)
    let clock: @Sendable () -> Date = {
        if let clockBox { return clockBox.read() }
        return Date()
    }
    let reader = SlackChannelsReader(provider: mock, ttl: ttl, clock: clock)
    return (reader, mock)
}

@MainActor
@Suite("SlackChannelsReader")
struct SlackChannelsReaderTests {

    // MARK: - Initial state

    @Test("initial state — channels empty, lastFetchedAt nil, isLoading false, error nil")
    func initialState() async {
        let (reader, mock) = makeReader()
        #expect(reader.channels.isEmpty)
        #expect(reader.lastFetchedAt == nil)
        #expect(reader.isLoading == false)
        #expect(reader.error == nil)
        let count = await mock.currentCallCount()
        #expect(count == 0)
    }

    // MARK: - refreshOnConnect

    @Test("refreshOnConnect populates channels + stamps lastFetchedAt")
    func refreshOnConnectPopulates() async {
        let canned = [
            SlackChannelsReader.SlackChannel(id: "C1", name: "general", isPrivate: false),
            SlackChannelsReader.SlackChannel(id: "C2", name: "secret", isPrivate: true)
        ]
        let (reader, mock) = makeReader(canned: canned)
        await reader.refreshOnConnect()
        #expect(reader.channels == canned)
        #expect(reader.lastFetchedAt != nil)
        #expect(reader.isLoading == false)
        #expect(reader.error == nil)
        let count = await mock.currentCallCount()
        #expect(count == 1)
    }

    // MARK: - refreshIfStale within TTL

    @Test("refreshIfStale within TTL is a no-op (provider not called again)")
    func refreshIfStaleWithinTTL() async {
        let canned = [SlackChannelsReader.SlackChannel(id: "C1", name: "general", isPrivate: false)]
        let (reader, mock) = makeReader(canned: canned)
        await reader.refreshOnConnect()
        await reader.refreshIfStale()
        let count = await mock.currentCallCount()
        #expect(count == 1)
    }

    // MARK: - refreshIfStale past TTL

    @Test("refreshIfStale after TTL refetches")
    func refreshIfStaleAfterTTL() async {
        let canned = [SlackChannelsReader.SlackChannel(id: "C1", name: "general", isPrivate: false)]
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let clockBox = ClockBox(now: t0)
        let (reader, mock) = makeReader(canned: canned, ttl: 300, clockBox: clockBox)
        await reader.refreshOnConnect()
        clockBox.advance(by: 301) // past TTL
        await reader.refreshIfStale()
        let count = await mock.currentCallCount()
        #expect(count == 2)
    }

    // MARK: - Provider error

    @Test("provider error → error field populated, channels unchanged")
    func providerError() async {
        struct E: LocalizedError {
            var errorDescription: String? { "network down" }
        }
        let canned = [SlackChannelsReader.SlackChannel(id: "C1", name: "general", isPrivate: false)]
        let (reader, _) = makeReader(canned: canned)
        await reader.refreshOnConnect()
        #expect(reader.channels.count == 1)
        #expect(reader.error == nil)

        // Swap to error provider via a fresh reader (separate test instance).
        let failingMock = MockSlackChannelsProvider(canned: [], error: E())
        let failingReader = SlackChannelsReader(provider: failingMock)
        await failingReader.refreshOnConnect()
        #expect(failingReader.error != nil)
        #expect(failingReader.error?.contains("network down") == true)
        #expect(failingReader.channels.isEmpty)
    }

    @Test("error from later refresh leaves previously-fetched channels intact")
    func errorPreservesChannels() async {
        struct E: LocalizedError {
            var errorDescription: String? { "transient" }
        }
        let initial = [SlackChannelsReader.SlackChannel(id: "C1", name: "general", isPrivate: false)]
        let mock = SwitchableMockSlackChannelsProvider(canned: initial)
        let reader = SlackChannelsReader(provider: mock, ttl: 300, clock: { Date() })
        await reader.refreshOnConnect()
        #expect(reader.channels.count == 1)
        await mock.setError(E())
        await reader.refreshOnConnect()   // forces re-fetch, will fail
        #expect(reader.error != nil)
        #expect(reader.channels == initial, "previously-cached channels survive failed refetch")
    }

    // MARK: - Concurrent refresh

    @Test("concurrent refresh calls do not double-fetch (isLoading guard)")
    func concurrentRefreshNoDoubleFetch() async {
        let canned = [SlackChannelsReader.SlackChannel(id: "C1", name: "general", isPrivate: false)]
        // Provider with artificial delay so the second call enters while the
        // first is still inflight.
        let mock = SlowMockSlackChannelsProvider(canned: canned, delayMs: 50)
        let reader = SlackChannelsReader(provider: mock, ttl: 300, clock: { Date() })
        async let a: Void = reader.refreshOnConnect()
        async let b: Void = reader.refreshOnConnect()
        _ = await (a, b)
        let count = await mock.currentCallCount()
        #expect(count == 1, "second concurrent refresh must coalesce into the inflight call")
    }
}

// MARK: - Test helpers

private actor MockSlackChannelsProvider: SlackChannelsProviding {
    private(set) var fetchCallCount = 0
    private let canned: [SlackChannelsReader.SlackChannel]
    private let error: Error?

    init(canned: [SlackChannelsReader.SlackChannel], error: Error? = nil) {
        self.canned = canned
        self.error = error
    }

    func fetchAccessibleChannels() async throws -> [SlackChannelsReader.SlackChannel] {
        fetchCallCount += 1
        if let error { throw error }
        return canned
    }

    func currentCallCount() -> Int { fetchCallCount }
}

private actor SwitchableMockSlackChannelsProvider: SlackChannelsProviding {
    private(set) var fetchCallCount = 0
    private var canned: [SlackChannelsReader.SlackChannel]
    private var error: Error?

    init(canned: [SlackChannelsReader.SlackChannel]) {
        self.canned = canned
        self.error = nil
    }

    func setError(_ error: Error?) { self.error = error }

    func fetchAccessibleChannels() async throws -> [SlackChannelsReader.SlackChannel] {
        fetchCallCount += 1
        if let error { throw error }
        return canned
    }

    func currentCallCount() -> Int { fetchCallCount }
}

private actor SlowMockSlackChannelsProvider: SlackChannelsProviding {
    private(set) var fetchCallCount = 0
    private let canned: [SlackChannelsReader.SlackChannel]
    private let delayMs: UInt64

    init(canned: [SlackChannelsReader.SlackChannel], delayMs: UInt64) {
        self.canned = canned
        self.delayMs = delayMs
    }

    func fetchAccessibleChannels() async throws -> [SlackChannelsReader.SlackChannel] {
        fetchCallCount += 1
        try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
        return canned
    }

    func currentCallCount() -> Int { fetchCallCount }
}

/// Mutable date holder for tests advancing simulated clock.
/// Class-based + NSLock keeps it Sendable-safe for the @escaping @Sendable
/// clock closure.
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
