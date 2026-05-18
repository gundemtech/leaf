//
//  SupabaseClientEnsureFreshSessionTests.swift
//  LeafCoreTests
//
//  Track 5 / S7 (post-S7 hot-fix P1) — JWT in-place refresh on Realtime reconnect.
//  Tests `SupabaseClient.ensureFreshSession()`:
//    • Returns cached session when not near-expiry.
//    • Triggers `/auth/v1/token` refresh when `exp - now < 60s`.
//    • Triggers refresh when `lastRefreshAt + 55min < now` (NTP-skew defense).
//    • Concurrent calls coalesce into a single inflight refresh Task.
//
//  Pattern mirrors SupabaseClientAuthBootstrapTests (URLSession injection via
//  MockURLProtocol, controllable `now` clock via SupabaseClient(now:) init).
//

import XCTest
import CryptoKit
import os.lock
@testable import LeafCore

final class SupabaseClientEnsureFreshSessionTests: XCTestCase {

    private let baseURL = URL(string: "https://test.supabase.co")!
    private let anonKey = "test-anon-key"

    override func tearDown() async throws {
        MockURLProtocol.handler = nil
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func fixedIdentity() -> @Sendable () throws -> Curve25519.KeyAgreement.PrivateKey {
        let bytes = Data(repeating: 0x42, count: 32)
        return { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bytes) }
    }

    private func makeJWT(pubkey: String, userID: String = "00000000-0000-0000-0000-000000000aaa") -> String {
        let header = #"{"alg":"HS256","typ":"JWT"}"#
        let payload = #"{"pubkey":"\#(pubkey)","sub":"\#(userID)"}"#
        func b64url(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(b64url(header)).\(b64url(payload)).sig"
    }

    /// Mutable clock holder readable from @Sendable handler closure.
    /// We can't capture a `var` directly in @Sendable; route via this box.
    final class ClockBox: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 0))
        func get() -> Date { lock.withLock { $0 } }
        func set(_ d: Date) { lock.withLock { $0 = d } }
    }

    final class CallCounter: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: [String: Int]())
        func increment(_ key: String) { lock.withLock { $0[key, default: 0] += 1 } }
        func get(_ key: String) -> Int { lock.withLock { $0[key] ?? 0 } }
    }

    /// Bootstrap a client whose first ensureAuthenticated lands a session whose
    /// `expiresAt` is `(clock.get() + initialExpiresInSec)`. The returned client's
    /// session is "current" relative to the clock at bootstrap time.
    private func bootstrap(client: SupabaseClient,
                           clock: ClockBox,
                           initialExpiresInSec: Int64) async throws {
        // Caller has already wired MockURLProtocol.handler.
        _ = try await client.ensureAuthenticated()
        _ = initialExpiresInSec  // documentation: caller controls via stub `expires_at`
    }

    // MARK: - Test 1 — NotExpiring → no refresh call

    func testEnsureFreshSession_NotExpiring_ReturnsCached() async throws {
        let clock = ClockBox()
        // Start clock at t=1000; session expires at t=1600 (600s away).
        clock.set(Date(timeIntervalSince1970: 1000))
        let pubkey = String(repeating: "42", count: 32)
        let initialJWT = makeJWT(pubkey: pubkey)
        let counter = CallCounter()

        MockURLProtocol.handler = { request, _ in
            let path = request.url?.path ?? ""
            counter.increment(path)
            switch path {
            case "/auth/v1/signup":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        """
                        { "access_token": "boot-tok", "refresh_token": "boot-rt",
                          "user": { "id": "00000000-0000-0000-0000-000000000aaa" },
                          "expires_at": 1600 }
                        """.data(using: .utf8)!)
            case "/functions/v1/register_pubkey":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"ok":true}"#.utf8))
            case "/auth/v1/token":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        """
                        { "access_token": "\(initialJWT)", "refresh_token": "ref-2",
                          "user": { "id": "00000000-0000-0000-0000-000000000aaa" },
                          "expires_at": 1600 }
                        """.data(using: .utf8)!)
            default:
                return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
        }

        let client = SupabaseClient(
            baseURL: baseURL, anonKey: anonKey,
            urlSession: makeSession(),
            identity: fixedIdentity(),
            now: { clock.get() }
        )
        // Bootstrap performs 3 round-trips: signup + register_pubkey + token (initial refresh).
        try await bootstrap(client: client, clock: clock, initialExpiresInSec: 600)
        XCTAssertEqual(counter.get("/auth/v1/token"), 1)

        // Now advance clock to t=1010 — session is still 590s from expiry, well past skew margin.
        clock.set(Date(timeIntervalSince1970: 1010))
        let session1 = try await client.ensureFreshSession()
        let session2 = try await client.ensureFreshSession()

        // Both calls return the same access_token, neither triggers a new /auth/v1/token.
        XCTAssertEqual(session1.accessToken, initialJWT)
        XCTAssertEqual(session2.accessToken, initialJWT)
        XCTAssertEqual(counter.get("/auth/v1/token"), 1,
                       "ensureFreshSession with no expiry pressure must NOT trigger refresh")
    }

    // MARK: - Test 2 — NearExpiry → refresh call

    func testEnsureFreshSession_NearExpiry_TriggersRefresh() async throws {
        let clock = ClockBox()
        // Start at t=1000; bootstrap session expires at t=1600.
        clock.set(Date(timeIntervalSince1970: 1000))
        let pubkey = String(repeating: "42", count: 32)
        let initialJWT = makeJWT(pubkey: pubkey)
        let refreshedJWT = makeJWT(pubkey: pubkey, userID: "00000000-0000-0000-0000-000000000bbb")
        let counter = CallCounter()
        // After bootstrap, the next /auth/v1/token call returns a refreshed token
        // whose exp is way out (10000) so the second ensureFreshSession is a no-op.
        let bootstrapDone = OSAllocatedUnfairLock(initialState: false)

        MockURLProtocol.handler = { request, _ in
            let path = request.url?.path ?? ""
            counter.increment(path)
            switch path {
            case "/auth/v1/signup":
                bootstrapDone.withLock { _ in /* nop */ }
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        """
                        { "access_token": "boot-tok", "refresh_token": "boot-rt",
                          "user": { "id": "00000000-0000-0000-0000-000000000aaa" },
                          "expires_at": 1600 }
                        """.data(using: .utf8)!)
            case "/functions/v1/register_pubkey":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"ok":true}"#.utf8))
            case "/auth/v1/token":
                let isPost = bootstrapDone.withLock { done -> Bool in
                    let was = done
                    done = true
                    return was
                }
                let body: String
                if isPost {
                    body = """
                    { "access_token": "\(refreshedJWT)", "refresh_token": "rotated-rt",
                      "user": { "id": "00000000-0000-0000-0000-000000000bbb" },
                      "expires_at": 10000 }
                    """
                } else {
                    body = """
                    { "access_token": "\(initialJWT)", "refresh_token": "ref-2",
                      "user": { "id": "00000000-0000-0000-0000-000000000aaa" },
                      "expires_at": 1600 }
                    """
                }
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        body.data(using: .utf8)!)
            default:
                return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
        }

        let client = SupabaseClient(
            baseURL: baseURL, anonKey: anonKey,
            urlSession: makeSession(),
            identity: fixedIdentity(),
            now: { clock.get() }
        )
        try await bootstrap(client: client, clock: clock, initialExpiresInSec: 600)
        XCTAssertEqual(counter.get("/auth/v1/token"), 1)

        // Advance clock to t=1580 — 20s from expiry, well under the 60s threshold.
        clock.set(Date(timeIntervalSince1970: 1580))
        let refreshed = try await client.ensureFreshSession()

        XCTAssertEqual(refreshed.accessToken, refreshedJWT)
        XCTAssertEqual(counter.get("/auth/v1/token"), 2,
                       "ensureFreshSession near expiry must trigger one /auth/v1/token refresh")
    }

    // MARK: - Test 3 — StalePastSkewMargin → refresh call

    func testEnsureFreshSession_StalePastSkewMargin_TriggersRefresh() async throws {
        let clock = ClockBox()
        clock.set(Date(timeIntervalSince1970: 1000))
        let pubkey = String(repeating: "42", count: 32)
        let initialJWT = makeJWT(pubkey: pubkey)
        // 2h-out expiry so the only refresh trigger is the lastRefreshAt skew margin.
        let refreshedJWT = makeJWT(pubkey: pubkey, userID: "00000000-0000-0000-0000-000000000ccc")
        let counter = CallCounter()
        let bootstrapDone = OSAllocatedUnfairLock(initialState: false)

        MockURLProtocol.handler = { request, _ in
            let path = request.url?.path ?? ""
            counter.increment(path)
            switch path {
            case "/auth/v1/signup":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        """
                        { "access_token": "boot-tok", "refresh_token": "boot-rt",
                          "user": { "id": "00000000-0000-0000-0000-000000000aaa" },
                          "expires_at": 8200 }
                        """.data(using: .utf8)!)
            case "/functions/v1/register_pubkey":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"ok":true}"#.utf8))
            case "/auth/v1/token":
                let isPost = bootstrapDone.withLock { done -> Bool in
                    let was = done
                    done = true
                    return was
                }
                let body: String
                if isPost {
                    body = """
                    { "access_token": "\(refreshedJWT)", "refresh_token": "rotated-rt",
                      "user": { "id": "00000000-0000-0000-0000-000000000ccc" },
                      "expires_at": 99999 }
                    """
                } else {
                    body = """
                    { "access_token": "\(initialJWT)", "refresh_token": "ref-2",
                      "user": { "id": "00000000-0000-0000-0000-000000000aaa" },
                      "expires_at": 8200 }
                    """
                }
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        body.data(using: .utf8)!)
            default:
                return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
        }

        let client = SupabaseClient(
            baseURL: baseURL, anonKey: anonKey,
            urlSession: makeSession(),
            identity: fixedIdentity(),
            now: { clock.get() }
        )
        try await bootstrap(client: client, clock: clock, initialExpiresInSec: 7200)
        XCTAssertEqual(counter.get("/auth/v1/token"), 1)

        // Advance to t=4400. Session expires at t=8200 → 3800s away (far from 60s threshold).
        // BUT bootstrap finished at t=1000 → lastRefreshAt is at t=1000.
        // 4400 - 1000 = 3400s > 55min (3300s) skew margin → must refresh.
        clock.set(Date(timeIntervalSince1970: 4400))
        let refreshed = try await client.ensureFreshSession()

        XCTAssertEqual(refreshed.accessToken, refreshedJWT)
        XCTAssertEqual(counter.get("/auth/v1/token"), 2,
                       "lastRefreshAt + 55min < now must trigger refresh even when exp is far")
    }

    // MARK: - Test 4 — Concurrent calls coalesce

    func testEnsureFreshSession_ConcurrentCalls_Coalesce() async throws {
        let clock = ClockBox()
        clock.set(Date(timeIntervalSince1970: 1000))
        let pubkey = String(repeating: "42", count: 32)
        let initialJWT = makeJWT(pubkey: pubkey)
        let refreshedJWT = makeJWT(pubkey: pubkey, userID: "00000000-0000-0000-0000-000000000ddd")
        let counter = CallCounter()
        let bootstrapDone = OSAllocatedUnfairLock(initialState: false)

        MockURLProtocol.handler = { request, _ in
            let path = request.url?.path ?? ""
            counter.increment(path)
            switch path {
            case "/auth/v1/signup":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        """
                        { "access_token": "boot-tok", "refresh_token": "boot-rt",
                          "user": { "id": "00000000-0000-0000-0000-000000000aaa" },
                          "expires_at": 1600 }
                        """.data(using: .utf8)!)
            case "/functions/v1/register_pubkey":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"ok":true}"#.utf8))
            case "/auth/v1/token":
                let isPost = bootstrapDone.withLock { done -> Bool in
                    let was = done
                    done = true
                    return was
                }
                let body: String
                if isPost {
                    body = """
                    { "access_token": "\(refreshedJWT)", "refresh_token": "rotated-rt",
                      "user": { "id": "00000000-0000-0000-0000-000000000ddd" },
                      "expires_at": 99999 }
                    """
                } else {
                    body = """
                    { "access_token": "\(initialJWT)", "refresh_token": "ref-2",
                      "user": { "id": "00000000-0000-0000-0000-000000000aaa" },
                      "expires_at": 1600 }
                    """
                }
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        body.data(using: .utf8)!)
            default:
                return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
        }

        let client = SupabaseClient(
            baseURL: baseURL, anonKey: anonKey,
            urlSession: makeSession(),
            identity: fixedIdentity(),
            now: { clock.get() }
        )
        try await bootstrap(client: client, clock: clock, initialExpiresInSec: 600)
        XCTAssertEqual(counter.get("/auth/v1/token"), 1)

        // Force near-expiry → three concurrent calls.
        clock.set(Date(timeIntervalSince1970: 1580))
        async let r1 = client.ensureFreshSession()
        async let r2 = client.ensureFreshSession()
        async let r3 = client.ensureFreshSession()
        let (s1, s2, s3) = try await (r1, r2, r3)

        XCTAssertEqual(s1.accessToken, refreshedJWT)
        XCTAssertEqual(s2.accessToken, refreshedJWT)
        XCTAssertEqual(s3.accessToken, refreshedJWT)
        XCTAssertEqual(counter.get("/auth/v1/token"), 2,
                       "3 concurrent ensureFreshSession calls must coalesce into 1 /auth/v1/token (bootstrap counted as #1)")
    }
}
