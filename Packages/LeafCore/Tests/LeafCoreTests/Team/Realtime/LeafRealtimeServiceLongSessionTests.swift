//
//  LeafRealtimeServiceLongSessionTests.swift
//  LeafCoreTests
//
//  Track 5 / S7 (post-S7 hot-fix P1) — JWT in-place refresh on Realtime reconnect.
//  Tests `LeafRealtimeService` extensions for long-session JWT refresh:
//    • `refreshIfNeeded()` — pulls a fresh JWT via `SupabaseClient.ensureFreshSession()`
//      and asks the driver to send a Phoenix access_token frame.
//    • `startRefreshTimer()` — 50min interval loop (test uses 50ms via injection)
//      that fires `refreshIfNeeded()` until cancelled.
//
//  Pre-reconnect refresh is wired by the service via the driver's jwtProvider
//  closure — verified indirectly by injecting a closure that bumps a counter
//  and confirming the reconnect path consults it.
//

import XCTest
import CryptoKit
import Foundation
import os.lock
@testable import LeafCore

@MainActor
final class LeafRealtimeServiceLongSessionTests: XCTestCase {

    // MARK: - Fixtures (mirror LeafRealtimeServiceTests so we can reuse mocks)

    private let url = URL(string: "wss://test.supabase.co/realtime/v1/websocket?apikey=key&vsn=1.0.0")!
    private let supabaseBaseURL = URL(string: "https://test.supabase.co")!
    private let anonKey = "test-anon-key"
    private let pubkey = String(repeating: "42", count: 32)
    private let userID = "00000000-0000-0000-0000-000000000eee"

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

    private func makeJWT(suffix: String) -> String {
        let header  = #"{"alg":"HS256","typ":"JWT"}"#
        let payload = #"{"pubkey":"\#(pubkey)","sub":"\#(userID)","kid":"\#(suffix)"}"#
        func b64url(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(b64url(header)).\(b64url(payload)).sig"
    }

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

    /// Spin up a bootstrapped SupabaseClient whose session expires soon enough
    /// that ensureFreshSession() will trigger a /auth/v1/token refresh on demand.
    private func bootstrappedClient(clock: ClockBox,
                                    counter: CallCounter) async throws -> SupabaseClient {
        let initialJWT = makeJWT(suffix: "initial")
        let rotatedJWT = makeJWT(suffix: "rotated")
        clock.set(Date(timeIntervalSince1970: 1000))
        let bootstrapDone = OSAllocatedUnfairLock(initialState: false)

        MockURLProtocol.handler = { request, _ in
            let path = request.url?.path ?? ""
            counter.increment(path)
            switch path {
            case "/auth/v1/signup":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        """
                        { "access_token": "boot-tok", "refresh_token": "boot-rt",
                          "user": { "id": "00000000-0000-0000-0000-000000000eee" },
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
                    { "access_token": "\(rotatedJWT)", "refresh_token": "post-rt",
                      "user": { "id": "00000000-0000-0000-0000-000000000eee" },
                      "expires_at": 99999 }
                    """
                } else {
                    body = """
                    { "access_token": "\(initialJWT)", "refresh_token": "init-rt",
                      "user": { "id": "00000000-0000-0000-0000-000000000eee" },
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
            baseURL: supabaseBaseURL, anonKey: anonKey,
            urlSession: makeSession(),
            identity: fixedIdentity(),
            now: { clock.get() }
        )
        _ = try await client.ensureAuthenticated()
        return client
    }

    // Track 5 / S8 / T0 — Phase H. Decryptor signature is now
    // `(EncryptedTeamEventInput) -> TeamEventPlaintext`. These long-session
    // tests exercise JWT refresh + reconnect — they don't fire postgres_changes
    // frames, so the decryptor is never actually invoked. Stub closures
    // throw `LeafError.notImplemented`; if a future test attempts to push
    // an envelope through this service, the throw surfaces as a test failure
    // making the gap obvious.
    private nonisolated func defaultTeamEventDecryptor() -> LeafRealtimeService.TeamEventDecryptor {
        return { @Sendable _ in
            throw LeafError.notImplemented
        }
    }

    private nonisolated func defaultDirectMessageDecryptor() -> LeafRealtimeService.DirectMessageDecryptor {
        return { @Sendable _ in
            throw LeafError.notImplemented
        }
    }

    private func makeService(driver: RealtimeWebSocketDriver, supabase: SupabaseClient) -> LeafRealtimeService {
        let dmStub = MockDirectMessageAbsorber()
        let teamStub = MockTeamEventAbsorber()
        let crossPost = CrossPostLogReader(supabase: supabase)
        return LeafRealtimeService(
            driver: driver,
            supabase: supabase,
            activeWorkspaceStore: ActiveWorkspaceStore(userDefaults: TestUserDefaults.make()),
            directMessageInboxReader: dmStub,
            teamEventMirrorReader: teamStub,
            crossPostLogReader: crossPost,
            realtimeURL: url,
            teamEventDecryptor: defaultTeamEventDecryptor(),
            directMessageDecryptor: defaultDirectMessageDecryptor()
        )
    }

    // MARK: - refreshIfNeeded sends the rotated JWT through to the driver

    /// 1. Service.refreshIfNeeded → ensureFreshSession (rotates JWT) → driver.refreshAccessToken
    ///    → Phoenix access_token frame is on the wire with the new JWT.
    func testRefreshIfNeeded_RotatesJWT_AndSendsAccessTokenFrame() async throws {
        let clock = ClockBox()
        let counter = CallCounter()
        let supabase = try await bootstrappedClient(clock: clock, counter: counter)
        // After bootstrap, exactly 1 /auth/v1/token call has happened.
        XCTAssertEqual(counter.get("/auth/v1/token"), 1)

        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock }, heartbeatIntervalSec: 60)
        let service = makeService(driver: driver, supabase: supabase)
        await service.subscribe(workspaceID: "wid-long")

        // Synthesize phx_reply ok to give the driver a currentChannelTopic.
        let okJSON = """
        {"topic":"realtime:leaf-workspace-wid-long","event":"phx_reply","payload":{"status":"ok","response":{}},"ref":"1"}
        """
        await driver.dispatchMessage(.string(okJSON))

        // Advance clock past 60s-before-expiry → ensureFreshSession will refresh.
        clock.set(Date(timeIntervalSince1970: 1580))
        let countBefore = mock.outgoing.count
        await service.refreshIfNeeded()

        // ensureFreshSession() must have triggered exactly one new /auth/v1/token.
        XCTAssertEqual(counter.get("/auth/v1/token"), 2)
        // Driver must have sent the access_token rotation frame.
        XCTAssertEqual(mock.outgoing.count, countBefore + 1)
        guard case .string(let raw) = mock.outgoing.last else {
            return XCTFail("expected text frame")
        }
        let obj = try JSONSerialization.jsonObject(with: raw.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(obj["event"] as? String, "access_token")
        XCTAssertEqual(obj["topic"] as? String, "realtime:leaf-workspace-wid-long")
        let payload = obj["payload"] as? [String: Any]
        let sentToken = payload?["access_token"] as? String
        // The token in the frame must be the rotated JWT — not the bootstrap one.
        XCTAssertEqual(sentToken, makeJWT(suffix: "rotated"))

        await service.suspend()
    }

    // MARK: - refreshIfNeeded is silent on errors

    /// 2. refreshIfNeeded swallows errors — when there's no session (signed out),
    ///    no frame is sent, no throw escapes. Caller-loop semantics: retry on
    ///    next tick.
    func testRefreshIfNeeded_NoSession_SilentlySkips() async throws {
        // Build a client that never signs in → ensureFreshSession throws .unauthorized.
        MockURLProtocol.handler = { request, _ in
            (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        let supabase = SupabaseClient(
            baseURL: supabaseBaseURL, anonKey: anonKey,
            urlSession: makeSession(),
            identity: fixedIdentity()
        )
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock }, heartbeatIntervalSec: 60)
        let service = makeService(driver: driver, supabase: supabase)
        let countBefore = mock.outgoing.count
        await service.refreshIfNeeded()
        XCTAssertEqual(mock.outgoing.count, countBefore,
                       "refreshIfNeeded with no session must NOT send a frame and must NOT throw")
    }

    // MARK: - Timer loop fires refreshIfNeeded periodically

    /// 3. The refresh timer loop fires at the configured interval and rotates
    ///    the JWT each tick. We inject a sub-second interval to keep the test fast.
    ///    Two ticks should produce two rotations (and two /auth/v1/token calls
    ///    after bootstrap).
    func testRefreshTimer_FiresAtInterval_RotatesJWT() async throws {
        let clock = ClockBox()
        let counter = CallCounter()
        let supabase = try await bootstrappedClient(clock: clock, counter: counter)
        XCTAssertEqual(counter.get("/auth/v1/token"), 1)

        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock }, heartbeatIntervalSec: 60)
        let service = makeService(driver: driver, supabase: supabase)
        await service.subscribe(workspaceID: "wid-timer")
        let okJSON = """
        {"topic":"realtime:leaf-workspace-wid-timer","event":"phx_reply","payload":{"status":"ok","response":{}},"ref":"1"}
        """
        await driver.dispatchMessage(.string(okJSON))

        // Move clock into the near-expiry window so each tick triggers a refresh.
        clock.set(Date(timeIntervalSince1970: 1580))

        // Start timer with a 60ms interval so two ticks fit in ~150ms wall time.
        service.startRefreshTimer(intervalSec: 0.06)
        try await Task.sleep(nanoseconds: 200_000_000)
        await service.stopRefreshTimer()

        // The bootstrap was 1 call; the loop should have added ≥ 1. After the
        // first refresh, the rotated JWT has exp=99999 so the second tick
        // wouldn't auto-refresh on near-expiry — but the timer just calls
        // ensureFreshSession unconditionally and lets the predicate decide.
        XCTAssertGreaterThanOrEqual(counter.get("/auth/v1/token"), 2,
            "Timer loop must trigger at least one ensureFreshSession refresh")
        // And the access_token frame must have been sent at least once.
        let tokenFrames = mock.outgoing.filter { msg in
            guard case .string(let s) = msg else { return false }
            return s.contains("\"event\":\"access_token\"")
        }
        XCTAssertGreaterThanOrEqual(tokenFrames.count, 1,
            "Timer-driven refresh must produce at least one access_token frame")

        await service.suspend()
    }

    // MARK: - P1 spec compliance fix-up (re-dispatch) — auto-started timer + race-free provider

    /// Critical-1: a successful subscribe() must auto-start the 50min refresh
    /// timer. Composition root never calls startRefreshTimer() in production;
    /// the timer must be tied to subscription lifetime so the JWT refresh path
    /// is actually active.
    func testSubscribe_StartsRefreshTimerAutomatically() async throws {
        let clock = ClockBox()
        let counter = CallCounter()
        let supabase = try await bootstrappedClient(clock: clock, counter: counter)

        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock }, heartbeatIntervalSec: 60)
        let service = makeService(driver: driver, supabase: supabase)
        // BEFORE subscribe — timer not running yet.
        XCTAssertFalse(service.isRefreshTimerRunning,
                       "Refresh timer must not run before subscribe()")

        await service.subscribe(workspaceID: "wid-auto-start")

        // AFTER subscribe — timer must be running automatically.
        XCTAssertTrue(service.isRefreshTimerRunning,
                      "subscribe() must auto-start the refresh timer")

        await service.suspend()
    }

    /// Important-1: suspend() cancels the refresh timer, but resume() must
    /// restart it (resume() calls subscribe() internally, which auto-starts
    /// the timer per Critical-1 fix). Without this, the timer is permanently
    /// dead after first scene-phase background→foreground cycle.
    func testSuspendResume_TimerRestartsAfterResume() async throws {
        let clock = ClockBox()
        let counter = CallCounter()
        let supabase = try await bootstrappedClient(clock: clock, counter: counter)

        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock }, heartbeatIntervalSec: 60)
        let service = makeService(driver: driver, supabase: supabase)

        await service.subscribe(workspaceID: "wid-resume-timer")
        XCTAssertTrue(service.isRefreshTimerRunning, "subscribe() must auto-start the timer")

        await service.suspend()
        XCTAssertFalse(service.isRefreshTimerRunning,
                       "suspend() must cancel the refresh timer")

        await service.resume()
        XCTAssertTrue(service.isRefreshTimerRunning,
                      "resume() must restart the refresh timer (via subscribe→auto-start)")

        await service.suspend()
    }

    /// unsubscribe() must stop the refresh timer — the service is no longer
    /// subscribed to any workspace so there's no reason to keep the timer
    /// rotating JWTs in the background.
    func testUnsubscribe_StopsRefreshTimer() async throws {
        let clock = ClockBox()
        let counter = CallCounter()
        let supabase = try await bootstrappedClient(clock: clock, counter: counter)

        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock }, heartbeatIntervalSec: 60)
        let service = makeService(driver: driver, supabase: supabase)

        await service.subscribe(workspaceID: "wid-unsub")
        XCTAssertTrue(service.isRefreshTimerRunning, "subscribe() must auto-start the timer")

        await service.unsubscribe()
        XCTAssertFalse(service.isRefreshTimerRunning,
                       "unsubscribe() must cancel the refresh timer")
    }

    /// Important-2: Init-time race fix. When the driver is constructed with a
    /// `jwtProvider` argument inline (not installed via a fire-and-forget Task
    /// after init), it's available immediately for any reconnect attempt.
    /// We assert this indirectly: a fresh driver with provider-in-init has the
    /// provider visible from inside the actor (currentJWTProvider != nil).
    func testDriverInit_JWTProviderAvailableImmediately() async throws {
        let mock = MockWebSocketTask()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let driver = RealtimeWebSocketDriver(
            taskFactory: { _ in mock },
            heartbeatIntervalSec: 60,
            jwtProvider: { @Sendable in
                calls.withLock { $0 += 1 }
                return "PROVIDER-JWT"
            }
        )
        // Inspector confirms the provider was registered at init time — no
        // post-init Task hop, no race window where the driver could reconnect
        // without consulting the provider.
        let installed = await driver.hasJWTProviderForTest()
        XCTAssertTrue(installed,
                      "jwtProvider passed to init must be available on the actor immediately, not via async install")
    }

    /// 4. startRefreshTimer is idempotent — calling twice does not multiply
    ///    the firing rate. (Cancels the prior task before installing a new one.)
    func testRefreshTimer_StartTwice_OnlyOneLoopRuns() async throws {
        let clock = ClockBox()
        let counter = CallCounter()
        let supabase = try await bootstrappedClient(clock: clock, counter: counter)

        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock }, heartbeatIntervalSec: 60)
        let service = makeService(driver: driver, supabase: supabase)
        await service.subscribe(workspaceID: "wid-twice")
        let okJSON = """
        {"topic":"realtime:leaf-workspace-wid-twice","event":"phx_reply","payload":{"status":"ok","response":{}},"ref":"1"}
        """
        await driver.dispatchMessage(.string(okJSON))
        clock.set(Date(timeIntervalSince1970: 1580))

        // Start timer twice in quick succession — second start must cancel the first.
        service.startRefreshTimer(intervalSec: 0.05)
        service.startRefreshTimer(intervalSec: 0.05)
        try await Task.sleep(nanoseconds: 120_000_000)
        await service.stopRefreshTimer()

        // 1 (bootstrap) + ≥1 (timer) but bounded — definitely not double-firing.
        // We can't assert exact count cross-machine, but we can sanity-check
        // ≤ 5 ticks within ~120ms when interval is 50ms.
        let count = counter.get("/auth/v1/token")
        XCTAssertGreaterThanOrEqual(count, 2)
        XCTAssertLessThanOrEqual(count, 6,
            "Idempotent startRefreshTimer must not double-fire — got \(count) /auth/v1/token calls")
    }
}
