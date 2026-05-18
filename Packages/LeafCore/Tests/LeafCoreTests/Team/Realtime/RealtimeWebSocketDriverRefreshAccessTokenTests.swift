//
//  RealtimeWebSocketDriverRefreshAccessTokenTests.swift
//  LeafCoreTests
//
//  Track 5 / S7 (post-S7 hot-fix P1) — JWT in-place refresh on Realtime reconnect.
//  Tests `RealtimeWebSocketDriver.refreshAccessToken(_:)`:
//    • When connected with a joined channel, sends a Phoenix `access_token`
//      frame on the channel topic. NO reconnect / NO disconnect.
//    • When disconnected (no joined channel), it's a silent no-op.
//
//  The Phoenix wire format for in-place rotation is built by
//  `RealtimePhoenixFrame.accessTokenRefresh` (already shipped in S7 D.1).
//

import XCTest
import os.lock
@testable import LeafCore

final class RealtimeWebSocketDriverRefreshAccessTokenTests: XCTestCase {

    private let url = URL(string: "wss://test.supabase.co/realtime/v1/websocket?apikey=key&vsn=1.0.0")!

    /// 1. Happy path — connected + joined channel + ack received → frame is sent.
    ///    Frame must carry topic=currentTopic, event="access_token", payload.access_token=new JWT.
    ///    The WS task is NOT cancelled (no reconnect).
    func testRefreshAccessToken_SendsPhoenixFrame_NoReconnect() async throws {
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(
            taskFactory: { _ in mock },
            heartbeatIntervalSec: 60   // disable heartbeat — keeps `outgoing` deterministic.
        )
        try await driver.connect(url: url, jwt: "old-jwt")
        try await driver.joinWorkspaceChannel(workspaceID: "wid-rotate", accessToken: "old-jwt")
        // Synthesize phx_reply ok so the driver records currentChannelTopic.
        let okJSON = """
        {"topic":"realtime:leaf-workspace-wid-rotate","event":"phx_reply","payload":{"status":"ok","response":{}},"ref":"1"}
        """
        await driver.dispatchMessage(.string(okJSON))
        let topic = await driver.currentTopic()
        XCTAssertEqual(topic, "realtime:leaf-workspace-wid-rotate")

        // Snapshot frame count before refresh.
        let countBefore = mock.outgoing.count
        let cancelCodeBefore = mock.cancelCode

        // ACT — rotate token in place.
        try await driver.refreshAccessToken("new-jwt")

        // ASSERT — exactly one new frame, of the expected shape.
        XCTAssertEqual(mock.outgoing.count, countBefore + 1,
                       "refreshAccessToken should send exactly 1 frame")
        guard case .string(let raw) = mock.outgoing.last else {
            return XCTFail("expected text frame")
        }
        let obj = try JSONSerialization.jsonObject(with: raw.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(obj["event"] as? String, "access_token")
        XCTAssertEqual(obj["topic"] as? String, "realtime:leaf-workspace-wid-rotate")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["access_token"] as? String, "new-jwt")
        XCTAssertNotNil(obj["ref"] as? String, "Phoenix frames carry a monotonic ref")

        // No reconnect: cancelCode unchanged + state still .connected.
        XCTAssertEqual(mock.cancelCode, cancelCodeBefore,
                       "refreshAccessToken must NOT cancel the WS task")
        let s = await driver.state
        XCTAssertEqual(s, .connected,
                       "refreshAccessToken must NOT alter driver state")
    }

    /// 2. No-op when no channel joined — driver not connected, refresh is silent.
    ///    Tests the (currentTopic == nil) branch protects against sending a
    ///    bogus frame with empty topic.
    func testRefreshAccessToken_NoChannel_SilentNoOp() async throws {
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock }, heartbeatIntervalSec: 60)
        // Never connect → never join.
        let countBefore = mock.outgoing.count
        try await driver.refreshAccessToken("new-jwt")
        XCTAssertEqual(mock.outgoing.count, countBefore,
                       "refreshAccessToken on a disconnected driver must be a silent no-op")
    }

    /// 3. JWT provider integration — when a `setJWTProvider` closure is installed,
    ///    `attemptReconnect()` consults it BEFORE rebuilding phx_join, so the
    ///    new connection uses a fresh JWT (not the cached stale `lastConnectJWT`).
    ///    Asserted indirectly: the phx_join frame on the second WS task carries
    ///    the fresh JWT from the provider, not the original "stale-jwt".
    func testReconnect_ConsultsJWTProvider_BeforeAttempt() async throws {
        let firstMock = MockWebSocketTask()
        let secondMock = MockWebSocketTask()
        let counter = OSAllocatedUnfairLockTestCounter()
        let factory: @Sendable (URLRequest) -> URLSessionWebSocketTaskProtocol = { _ in
            counter.increment()
            return counter.value == 1 ? firstMock : secondMock
        }
        let driver = RealtimeWebSocketDriver(
            taskFactory: factory,
            heartbeatIntervalSec: 60.0,
            reconnectBaseDelayMs: 20,
            reconnectMaxDelayMs: 40
        )
        await driver.setJWTProvider({ "FRESH-JWT-FROM-PROVIDER" })

        try await driver.connect(url: url, jwt: "STALE-JWT-CACHED-AT-INIT")
        try await driver.joinWorkspaceChannel(workspaceID: "wid-provider", accessToken: "STALE-JWT-CACHED-AT-INIT")
        // Synthesize ack so currentChannelTopic is set.
        let okJSON = """
        {"topic":"realtime:leaf-workspace-wid-provider","event":"phx_reply","payload":{"status":"ok","response":{}},"ref":"1"}
        """
        await driver.dispatchMessage(.string(okJSON))

        // Trigger loss → reconnect cycle picks up fresh JWT from provider.
        firstMock.enqueueError(URLError(.networkConnectionLost))
        try await Task.sleep(nanoseconds: 250_000_000)

        // The second WS task should have seen a phx_join carrying the provider's JWT.
        let secondJoin = secondMock.outgoing.first(where: { msg in
            guard case .string(let s) = msg else { return false }
            return s.contains("\"event\":\"phx_join\"")
        })
        XCTAssertNotNil(secondJoin, "expected phx_join on the second WS task after reconnect")
        if case .string(let raw) = secondJoin! {
            XCTAssertTrue(raw.contains("\"access_token\":\"FRESH-JWT-FROM-PROVIDER\""),
                          "phx_join must carry the provider's fresh JWT, not the stale cached one. Got: \(raw)")
            XCTAssertFalse(raw.contains("STALE-JWT-CACHED-AT-INIT"),
                           "phx_join must NOT replay the stale JWT")
        }
        await driver.disconnect()
    }
}

// MARK: - Test-side counter

final class OSAllocatedUnfairLockTestCounter: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: 0)
    func increment() { lock.withLock { $0 += 1 } }
    var value: Int { lock.withLock { $0 } }
}
