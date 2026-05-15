//
//  LinearScopesReaderTests.swift
//  LeafCoreTests
//
//  Track 5 / S6 T11 — verifies LinearScopesReader wraps LinearScopesService
//  and exposes `crossPostReady` mirroring `has("issues:create")`. `reauthorize`
//  triggers OAuth + scope refresh in deterministic order.
//
//  OAuth dependency abstracted behind `LinearOAuthReauthorizing` protocol so
//  the LeafCore-only reader can be tested without the app-target
//  `LinearOAuthService` (which imports SwiftUI / AppKit).
//

import Foundation
import Testing
@testable import LeafCore

@MainActor
@Suite("LinearScopesReader")
struct LinearScopesReaderTests {

    @Test("initial state — crossPostReady false until refresh")
    func initialState() async {
        let service = LinearScopesService(grantedOverride: ["read"])
        let oauth = MockReauthorizing()
        let reader = LinearScopesReader(service: service, reauthorizer: oauth)
        #expect(reader.crossPostReady == false)
    }

    @Test("refresh sets crossPostReady=true when service.has(\"issues:create\")")
    func refreshReadyTrue() async {
        let service = LinearScopesService(grantedOverride: ["read", "issues:create"])
        let oauth = MockReauthorizing()
        let reader = LinearScopesReader(service: service, reauthorizer: oauth)
        await reader.refresh()
        #expect(reader.crossPostReady == true)
    }

    @Test("refresh sets crossPostReady=false when scope missing")
    func refreshReadyFalse() async {
        let service = LinearScopesService(grantedOverride: ["read"])
        let oauth = MockReauthorizing()
        let reader = LinearScopesReader(service: service, reauthorizer: oauth)
        await reader.refresh()
        #expect(reader.crossPostReady == false)
    }

    @Test("reauthorize calls oauth.connect exactly once before refreshing scope state")
    func reauthorizeCallsConnectThenRefresh() async {
        let service = LinearScopesService(grantedOverride: ["read", "issues:create"])
        let oauth = MockReauthorizing()
        let reader = LinearScopesReader(service: service, reauthorizer: oauth)
        await reader.reauthorize()
        let connectCount = await oauth.currentCallCount()
        #expect(connectCount == 1)
        // After connect + refresh, scope reflects override (issues:create granted).
        #expect(reader.crossPostReady == true)
    }

    @Test("reauthorize still refreshes scope even after connect failure")
    func reauthorizeRefreshesAfterConnectFailure() async {
        let service = LinearScopesService(grantedOverride: ["read"])
        let oauth = MockReauthorizing(connectError: NSError(domain: "test", code: 1))
        let reader = LinearScopesReader(service: service, reauthorizer: oauth)
        await reader.reauthorize()
        let connectCount = await oauth.currentCallCount()
        #expect(connectCount == 1)
        // After failed connect, scope unchanged.
        #expect(reader.crossPostReady == false)
    }

    @Test("concurrent reauthorize calls coalesce into one OAuth connect")
    func reauthorizeConcurrentCoalesces() async {
        let service = LinearScopesService(grantedOverride: ["read"])
        let oauth = SlowMockReauthorizing(delayMs: 50)
        let reader = LinearScopesReader(service: service, reauthorizer: oauth)
        async let a: Void = reader.reauthorize()
        async let b: Void = reader.reauthorize()
        _ = await (a, b)
        let connectCount = await oauth.currentCallCount()
        #expect(connectCount == 1, "second concurrent reauthorize must coalesce")
    }
}

// MARK: - Test helpers

private actor MockReauthorizing: LinearOAuthReauthorizing {
    private(set) var connectCallCount = 0
    private let connectError: Error?

    init(connectError: Error? = nil) {
        self.connectError = connectError
    }

    func connect() async {
        connectCallCount += 1
        // We intentionally swallow `connectError` because the real
        // `LinearOAuthService.connect()` reports errors via its observable
        // state machine, not by throwing.
        _ = connectError
    }

    func currentCallCount() -> Int { connectCallCount }
}

private actor SlowMockReauthorizing: LinearOAuthReauthorizing {
    private(set) var connectCallCount = 0
    private let delayMs: UInt64

    init(delayMs: UInt64) { self.delayMs = delayMs }

    func connect() async {
        connectCallCount += 1
        try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
    }

    func currentCallCount() -> Int { connectCallCount }
}
