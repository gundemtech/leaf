//
//  RealtimeWebSocketDriverTests.swift
//  LeafCoreTests
//
//  Track 5 / S7 — Phase D.2 + D.3 + D.4. Driver actor exercising:
//   • state machine (disconnected → connecting → connected → disconnected)
//   • phx_join → ack → channelJoined event
//   • postgres_changes → typed events (teamEventInserted / directMessageInserted / Updated)
//   • silent skip on unknown table + malformed JSON
//   • leave + disconnect lifecycle
//
//  All tests use injected MockWebSocketTask; no real WS connection.
//

import XCTest
import os.lock
@testable import LeafCore

final class RealtimeWebSocketDriverTests: XCTestCase {

    private let url = URL(string: "wss://test.supabase.co/realtime/v1/websocket?apikey=key&vsn=1.0.0")!

    // MARK: - Lifecycle

    func testInitialState_Disconnected() async {
        let driver = RealtimeWebSocketDriver()
        let s = await driver.state
        XCTAssertEqual(s, .disconnected)
    }

    func testConnect_TransitionsToConnected_AndResumesTask() async throws {
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock })
        try await driver.connect(url: url, jwt: "JWT.xx")
        let s = await driver.state
        XCTAssertEqual(s, .connected)
        XCTAssertTrue(mock.isResumed)
    }

    func testConnect_Idempotent_WhileConnected_NoSecondResume() async throws {
        let mock = MockWebSocketTask()
        let counter = AtomicCounter()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in
            counter.increment()
            return mock
        })
        try await driver.connect(url: url, jwt: "JWT.xx")
        try await driver.connect(url: url, jwt: "JWT.xx")
        XCTAssertEqual(counter.value, 1)
    }

    func testDisconnect_TransitionsToDisconnected_AndCancelsTask() async throws {
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock })
        try await driver.connect(url: url, jwt: "JWT.xx")
        await driver.disconnect()
        let s = await driver.state
        XCTAssertEqual(s, .disconnected)
        XCTAssertEqual(mock.cancelCode, .normalClosure)
    }

    // MARK: - phx_join

    func testJoinWorkspaceChannel_SendsPhxJoin_WithCorrectTopic() async throws {
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock })
        try await driver.connect(url: url, jwt: "JWT.xx")
        try await driver.joinWorkspaceChannel(workspaceID: "wid-123", accessToken: "tok")
        XCTAssertEqual(mock.outgoing.count, 1)
        guard case .string(let json) = mock.outgoing.first else {
            return XCTFail("expected text frame")
        }
        let obj = try JSONSerialization.jsonObject(with: json.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(obj["topic"] as? String, "realtime:leaf-workspace-wid-123")
        XCTAssertEqual(obj["event"] as? String, "phx_join")
    }

    func testJoinWorkspaceChannel_NotConnected_Throws() async throws {
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock })
        do {
            try await driver.joinWorkspaceChannel(workspaceID: "wid", accessToken: "tok")
            XCTFail("expected throw")
        } catch RealtimeError.notConnected {
            // ok
        }
    }

    func testJoinWorkspaceChannel_RefMonotonic() async throws {
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock })
        try await driver.connect(url: url, jwt: "JWT.xx")
        try await driver.joinWorkspaceChannel(workspaceID: "w1", accessToken: "t")
        try await driver.joinWorkspaceChannel(workspaceID: "w2", accessToken: "t")
        let refs = mock.outgoing.compactMap { frame -> String? in
            guard case .string(let s) = frame,
                  let data = s.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return obj["ref"] as? String
        }
        XCTAssertEqual(refs, ["1", "2"])
    }

    // MARK: - Dispatch — phx_reply

    func testDispatch_PhxReplyOK_YieldsChannelJoined() async throws {
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock })
        let stream = await driver.events
        try await driver.connect(url: url, jwt: "JWT.xx")
        let json = """
        {"topic":"realtime:leaf-workspace-wid","event":"phx_reply","payload":{"status":"ok","response":{}},"ref":"1"}
        """
        await driver.dispatchMessage(.string(json))
        let evt = await firstEvent(from: stream)
        guard case .channelJoined(let topic) = evt else {
            return XCTFail("expected .channelJoined got \(String(describing: evt))")
        }
        XCTAssertEqual(topic, "realtime:leaf-workspace-wid")
        // and currentTopic mirror:
        let current = await driver.currentTopic()
        XCTAssertEqual(current, "realtime:leaf-workspace-wid")
    }

    func testDispatch_PhxReplyError_YieldsChannelRejected() async throws {
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock })
        let stream = await driver.events
        try await driver.connect(url: url, jwt: "JWT.xx")
        let json = """
        {"topic":"realtime:leaf-workspace-wid","event":"phx_reply","payload":{"status":"error","response":{"reason":"rls-denied"}},"ref":"1"}
        """
        await driver.dispatchMessage(.string(json))
        let evt = await firstEvent(from: stream)
        guard case .channelRejected(let topic, let reason) = evt else {
            return XCTFail("expected .channelRejected got \(String(describing: evt))")
        }
        XCTAssertEqual(topic, "realtime:leaf-workspace-wid")
        XCTAssertEqual(reason, "rls-denied")
    }

    // MARK: - Dispatch — postgres_changes

    func testDispatch_TeamEventsInsert_YieldsTeamEventInserted() async throws {
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock })
        let stream = await driver.events
        try await driver.connect(url: url, jwt: "JWT.xx")
        let recordJSON: [String: Any] = [
            "event_id": "ev-1",
            "workspace_id": "wid-1",
            "sender_pubkey": String(repeating: "a", count: 64),
            "source_kind": "git_commits",
            "kind": "commit_authored",
            "encrypted_payload": "\\x041122334455",
            "created_at": "2026-05-18T12:00:00.123Z",
            "expires_at": "2026-06-17T12:00:00.123Z",
        ]
        let payload: [String: Any] = [
            "data": ["type": "INSERT", "table": "team_events", "record": recordJSON]
        ]
        let envelope: [String: Any] = [
            "topic": "realtime:leaf-workspace-wid-1",
            "event": "postgres_changes",
            "payload": payload,
            "ref": NSNull(),
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        let json = String(data: data, encoding: .utf8)!
        await driver.dispatchMessage(.string(json))
        let evt = await firstEvent(from: stream)
        guard case .teamEventInserted(let row) = evt else {
            return XCTFail("expected .teamEventInserted got \(String(describing: evt))")
        }
        XCTAssertEqual(row.eventID, "ev-1")
        XCTAssertEqual(row.workspaceID, "wid-1")
        XCTAssertEqual(row.sourceKind, "git_commits")
        XCTAssertEqual(row.kind, "commit_authored")
        XCTAssertEqual(row.encryptedPayload, Data([0x04, 0x11, 0x22, 0x33, 0x44, 0x55]))
    }

    func testDispatch_DirectMessagesInsert_YieldsDirectMessageInserted() async throws {
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock })
        let stream = await driver.events
        try await driver.connect(url: url, jwt: "JWT.xx")
        let recordJSON: [String: Any] = [
            "message_id": "msg-1",
            "workspace_id": "wid-1",
            "sender_pubkey": String(repeating: "a", count: 64),
            "recipient_pubkey": String(repeating: "b", count: 64),
            "kind": "handoff",
            "encrypted_payload": "\\xdeadbeef",
            "created_at": "2026-05-18T12:00:00.123Z",
        ]
        let envelope: [String: Any] = [
            "topic": "realtime:leaf-workspace-wid-1",
            "event": "postgres_changes",
            "payload": ["data": ["type": "INSERT", "table": "direct_messages", "record": recordJSON]],
            "ref": NSNull(),
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        let json = String(data: data, encoding: .utf8)!
        await driver.dispatchMessage(.string(json))
        let evt = await firstEvent(from: stream)
        guard case .directMessageInserted(let row) = evt else {
            return XCTFail("expected .directMessageInserted got \(String(describing: evt))")
        }
        XCTAssertEqual(row.messageID, "msg-1")
        XCTAssertEqual(row.kind, "handoff")
        XCTAssertEqual(row.encryptedPayload, Data([0xde, 0xad, 0xbe, 0xef]))
    }

    func testDispatch_DirectMessagesUpdate_YieldsDirectMessageUpdated() async throws {
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock })
        let stream = await driver.events
        try await driver.connect(url: url, jwt: "JWT.xx")
        let recordJSON: [String: Any] = [
            "message_id": "msg-1",
            "workspace_id": "wid-1",
            "sender_pubkey": String(repeating: "a", count: 64),
            "recipient_pubkey": String(repeating: "b", count: 64),
            "kind": "handoff",
            "encrypted_payload": "\\xdeadbeef",
            "created_at": "2026-05-18T12:00:00.123Z",
            "read_at": "2026-05-18T12:05:00.000Z",
        ]
        let envelope: [String: Any] = [
            "topic": "realtime:leaf-workspace-wid-1",
            "event": "postgres_changes",
            "payload": ["data": ["type": "UPDATE", "table": "direct_messages", "record": recordJSON]],
            "ref": NSNull(),
        ]
        let json = String(data: try JSONSerialization.data(withJSONObject: envelope), encoding: .utf8)!
        await driver.dispatchMessage(.string(json))
        let evt = await firstEvent(from: stream)
        guard case .directMessageUpdated(let row) = evt else {
            return XCTFail("expected .directMessageUpdated got \(String(describing: evt))")
        }
        XCTAssertEqual(row.messageID, "msg-1")
        XCTAssertEqual(row.readAtISO, "2026-05-18T12:05:00.000Z")
    }

    func testDispatch_UnknownTable_SilentlySkipped() async throws {
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock })
        let stream = await driver.events
        try await driver.connect(url: url, jwt: "JWT.xx")
        let envelope: [String: Any] = [
            "topic": "realtime:leaf-workspace-wid",
            "event": "postgres_changes",
            "payload": ["data": ["type": "INSERT", "table": "unknown_table", "record": ["id": "x"]]],
            "ref": NSNull(),
        ]
        let json = String(data: try JSONSerialization.data(withJSONObject: envelope), encoding: .utf8)!
        await driver.dispatchMessage(.string(json))
        // No event should be yielded — assert timeout to confirm silent skip.
        let timedOut = await noEventWithin(stream: stream, seconds: 0.25)
        XCTAssertTrue(timedOut, "Unknown table should not yield any event")
    }

    func testDispatch_MalformedJSON_SilentlySkipped() async throws {
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock })
        let stream = await driver.events
        try await driver.connect(url: url, jwt: "JWT.xx")
        await driver.dispatchMessage(.string("not-json"))
        let timedOut = await noEventWithin(stream: stream, seconds: 0.25)
        XCTAssertTrue(timedOut)
    }

    func testDispatch_PhxClose_YieldsDisconnected_AndTransitions() async throws {
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock })
        let stream = await driver.events
        try await driver.connect(url: url, jwt: "JWT.xx")
        let json = """
        {"topic":"realtime:leaf-workspace-wid","event":"phx_close","payload":{},"ref":null}
        """
        await driver.dispatchMessage(.string(json))
        let evt = await firstEvent(from: stream)
        guard case .disconnected(let reason) = evt else {
            return XCTFail("expected .disconnected got \(String(describing: evt))")
        }
        XCTAssertEqual(reason, "phx_close")
        let s = await driver.state
        XCTAssertEqual(s, .disconnected)
    }

    // MARK: - Leave

    func testLeaveCurrentChannel_NoOp_WhenNotJoined() async throws {
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock })
        try await driver.connect(url: url, jwt: "JWT.xx")
        await driver.leaveCurrentChannel()
        // Should send nothing (no topic to leave).
        XCTAssertTrue(mock.outgoing.isEmpty)
    }

    func testLeaveCurrentChannel_SendsPhxLeave_AfterJoinAck() async throws {
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock })
        try await driver.connect(url: url, jwt: "JWT.xx")
        try await driver.joinWorkspaceChannel(workspaceID: "wid", accessToken: "tok")
        // Synthesize the phx_reply ok so the driver records currentChannelTopic.
        let okJSON = """
        {"topic":"realtime:leaf-workspace-wid","event":"phx_reply","payload":{"status":"ok","response":{}},"ref":"1"}
        """
        await driver.dispatchMessage(.string(okJSON))
        await driver.leaveCurrentChannel()
        XCTAssertEqual(mock.outgoing.count, 2)
        guard case .string(let frame) = mock.outgoing.last else {
            return XCTFail("expected text frame")
        }
        let obj = try JSONSerialization.jsonObject(with: frame.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(obj["event"] as? String, "phx_leave")
        XCTAssertEqual(obj["topic"] as? String, "realtime:leaf-workspace-wid")
    }

    // MARK: - Helpers

    /// Read the first event from the stream with a small timeout. Returns nil on timeout.
    private func firstEvent(from stream: AsyncStream<RealtimeEvent>) async -> RealtimeEvent? {
        await withTaskGroup(of: RealtimeEvent?.self) { group in
            group.addTask {
                for await evt in stream { return evt }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    /// Thread-safe counter for Sendable-capture-friendly test assertions.
    final class AtomicCounter: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: 0)
        func increment() { lock.withLock { $0 += 1 } }
        var value: Int { lock.withLock { $0 } }
    }

    /// Returns true if no event arrived on the stream within `seconds`.
    private func noEventWithin(stream: AsyncStream<RealtimeEvent>, seconds: Double) async -> Bool {
        let result = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in stream { return false }
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return true
            }
            let r = await group.next() ?? true
            group.cancelAll()
            return r
        }
        return result
    }
}

// MARK: - Heartbeat tests (D.5)

/// Track 5 / S7 — D.5 heartbeat suite. Exercises the 30s tick loop, the
/// `phx_reply` reset path, and the 3-missed-tick reconnect trigger.
/// All tests use heartbeatIntervalSec=0.05 (50ms) to keep wall time low.
final class RealtimeHeartbeatTests: XCTestCase {

    private let url = URL(string: "wss://test.supabase.co/realtime/v1/websocket?apikey=key&vsn=1.0.0")!

    /// On connect, the heartbeat loop starts and within a tick interval we
    /// observe a heartbeat frame on the wire.
    func testHeartbeat_StartsOnConnect() async throws {
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(
            taskFactory: { _ in mock },
            heartbeatIntervalSec: 0.05
        )
        try await driver.connect(url: url, jwt: "JWT.xx")
        // Wait for ~2 tick intervals → expect at least one heartbeat frame.
        try await Task.sleep(nanoseconds: 150_000_000)
        let hbCount = mock.outgoing.filter { msg in
            guard case .string(let s) = msg else { return false }
            return s.contains("\"event\":\"heartbeat\"")
        }.count
        XCTAssertGreaterThanOrEqual(hbCount, 1, "expected at least one heartbeat frame")
        await driver.disconnect()
    }

    /// The heartbeat frame matches the Phoenix wire format:
    ///   topic="phoenix", event="heartbeat", payload={}, ref="hb-<N>"
    func testHeartbeat_FramePayload() async throws {
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(
            taskFactory: { _ in mock },
            heartbeatIntervalSec: 0.05
        )
        try await driver.connect(url: url, jwt: "JWT.xx")
        try await Task.sleep(nanoseconds: 100_000_000)
        await driver.disconnect()
        let hbFrame = mock.outgoing.compactMap { msg -> String? in
            guard case .string(let s) = msg else { return nil }
            return s.contains("\"event\":\"heartbeat\"") ? s : nil
        }.first
        guard let frameJSON = hbFrame else {
            return XCTFail("no heartbeat frame captured")
        }
        let obj = try JSONSerialization.jsonObject(with: frameJSON.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(obj["topic"] as? String, "phoenix")
        XCTAssertEqual(obj["event"] as? String, "heartbeat")
        let payload = obj["payload"] as? [String: Any]
        XCTAssertNotNil(payload)
        XCTAssertTrue(payload?.isEmpty == true, "heartbeat payload must be empty object")
        if let ref = obj["ref"] as? String {
            XCTAssertTrue(ref.hasPrefix("hb-"), "ref should be 'hb-N', got \(ref)")
        } else {
            XCTFail("expected ref string with 'hb-' prefix")
        }
    }

    /// A phx_reply on topic="phoenix" with status="ok" resets the missed-heartbeat
    /// counter. Verified via the test-only `currentMissedHeartbeats()` inspector.
    func testHeartbeat_ServerReplyResetsCounter() async throws {
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(
            taskFactory: { _ in mock },
            heartbeatIntervalSec: 0.05
        )
        try await driver.connect(url: url, jwt: "JWT.xx")
        // Let one tick fire (counter → 1 unanswered).
        try await Task.sleep(nanoseconds: 100_000_000)
        let beforeReply = await driver.currentMissedHeartbeats()
        XCTAssertGreaterThanOrEqual(beforeReply, 1)
        // Synthesize the server's phx_reply for heartbeat.
        let reply = """
        {"topic":"phoenix","event":"phx_reply","payload":{"status":"ok","response":{}},"ref":"hb-1"}
        """
        await driver.dispatchMessage(.string(reply))
        let afterReply = await driver.currentMissedHeartbeats()
        XCTAssertEqual(afterReply, 0, "heartbeat reply must reset missed counter")
        await driver.disconnect()
    }

    /// After 3 consecutive unanswered heartbeats, the driver assumes the server
    /// is dead, emits .disconnected, and transitions out of .connected. With
    /// captured URL/JWT, the reconnect loop kicks in → state becomes .reconnecting.
    func testHeartbeat_ThreeMissedTriggersReconnect() async throws {
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(
            taskFactory: { _ in mock },
            heartbeatIntervalSec: 0.03,
            missingHeartbeatLimit: 3,
            reconnectBaseDelayMs: 5_000   // big enough that we observe .reconnecting before connect retry
        )
        let stream = await driver.events
        try await driver.connect(url: url, jwt: "JWT.xx")
        // Sleep ~5 tick intervals — 3+ heartbeats fire unanswered → trigger reconnect.
        try await Task.sleep(nanoseconds: 300_000_000)
        // Drain stream until we see .disconnected.
        let disc = await firstDisconnectEvent(from: stream, withinSec: 0.5)
        XCTAssertNotNil(disc, "expected .disconnected event after 3 missed heartbeats")
        // After handleConnectionLoss → startReconnectLoop, state should be .reconnecting.
        // Allow brief window for the reconnect task to set state.
        try await Task.sleep(nanoseconds: 50_000_000)
        let s = await driver.state
        if case .reconnecting = s {
            // ok
        } else {
            XCTFail("expected .reconnecting state, got \(s)")
        }
        await driver.disconnect()
    }

    /// disconnect() cancels the heartbeat loop — no further heartbeat frames after.
    func testHeartbeat_StopsOnDisconnect() async throws {
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(
            taskFactory: { _ in mock },
            heartbeatIntervalSec: 0.05
        )
        try await driver.connect(url: url, jwt: "JWT.xx")
        try await Task.sleep(nanoseconds: 80_000_000)
        await driver.disconnect()
        let countAtDisconnect = mock.outgoing.filter { msg in
            guard case .string(let s) = msg else { return false }
            return s.contains("\"event\":\"heartbeat\"")
        }.count
        // Wait several more intervals — count must NOT grow.
        try await Task.sleep(nanoseconds: 200_000_000)
        let countAfter = mock.outgoing.filter { msg in
            guard case .string(let s) = msg else { return false }
            return s.contains("\"event\":\"heartbeat\"")
        }.count
        XCTAssertEqual(countAtDisconnect, countAfter, "heartbeat must stop after disconnect()")
    }

    // MARK: - Helpers

    /// Wait for the first .disconnected event on the stream (with timeout).
    private func firstDisconnectEvent(from stream: AsyncStream<RealtimeEvent>, withinSec: Double) async -> RealtimeEvent? {
        await withTaskGroup(of: RealtimeEvent?.self) { group in
            group.addTask {
                for await evt in stream {
                    if case .disconnected = evt { return evt }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(withinSec * 1_000_000_000))
                return nil
            }
            let r = await group.next() ?? nil
            group.cancelAll()
            return r
        }
    }
}

// MARK: - Reconnect tests (D.6)

/// Track 5 / S7 — D.6 reconnect suite. Exercises the exponential backoff
/// schedule (pure-functional), state transitions on connection loss, attempt
/// counter behavior, and suspend/resume semantics.
final class RealtimeReconnectTests: XCTestCase {

    private let url = URL(string: "wss://test.supabase.co/realtime/v1/websocket?apikey=key&vsn=1.0.0")!

    // MARK: - Pure-function backoff schedule

    /// The backoff schedule is exactly 1s, 2s, 4s, 8s, 16s for attempts 1-5.
    /// Pure-functional — no Task.sleep / async involved.
    func testReconnect_BackoffSchedule_1_2_4_8_16() {
        XCTAssertEqual(RealtimeWebSocketDriver.delayForReconnectAttempt(1), 1_000)
        XCTAssertEqual(RealtimeWebSocketDriver.delayForReconnectAttempt(2), 2_000)
        XCTAssertEqual(RealtimeWebSocketDriver.delayForReconnectAttempt(3), 4_000)
        XCTAssertEqual(RealtimeWebSocketDriver.delayForReconnectAttempt(4), 8_000)
        XCTAssertEqual(RealtimeWebSocketDriver.delayForReconnectAttempt(5), 16_000)
    }

    /// After attempt 5, the delay caps at 16s (steady-state for multi-day outages).
    func testReconnect_BackoffCappedAt16s() {
        XCTAssertEqual(RealtimeWebSocketDriver.delayForReconnectAttempt(6), 16_000)
        XCTAssertEqual(RealtimeWebSocketDriver.delayForReconnectAttempt(50), 16_000)
        XCTAssertEqual(RealtimeWebSocketDriver.delayForReconnectAttempt(1_000_000), 16_000)
    }

    /// Custom baseMs/maxMs scale the schedule proportionally — used internally
    /// for fast test runs and demonstrates that the formula is parameterized.
    func testReconnect_CustomBaseAndMax_ScalesSchedule() {
        // base=10ms, max=80ms → 10, 20, 40, 80, 80, 80
        XCTAssertEqual(RealtimeWebSocketDriver.delayForReconnectAttempt(1, baseMs: 10, maxMs: 80), 10)
        XCTAssertEqual(RealtimeWebSocketDriver.delayForReconnectAttempt(2, baseMs: 10, maxMs: 80), 20)
        XCTAssertEqual(RealtimeWebSocketDriver.delayForReconnectAttempt(3, baseMs: 10, maxMs: 80), 40)
        XCTAssertEqual(RealtimeWebSocketDriver.delayForReconnectAttempt(4, baseMs: 10, maxMs: 80), 80)
        XCTAssertEqual(RealtimeWebSocketDriver.delayForReconnectAttempt(5, baseMs: 10, maxMs: 80), 80)
        XCTAssertEqual(RealtimeWebSocketDriver.delayForReconnectAttempt(100, baseMs: 10, maxMs: 80), 80)
    }

    /// Defensive: attempt=0 or negative is treated as attempt=1 (no underflow).
    func testReconnect_BackoffNonPositiveAttempt_TreatedAsFirst() {
        XCTAssertEqual(RealtimeWebSocketDriver.delayForReconnectAttempt(0), 1_000)
        XCTAssertEqual(RealtimeWebSocketDriver.delayForReconnectAttempt(-1), 1_000)
    }

    // MARK: - Integration: connection loss → reconnecting

    /// When the WS receive() throws, the driver transitions to .reconnecting
    /// (via handleConnectionLoss → startReconnectLoop). Captured URL/JWT are
    /// what enables the loop to proceed.
    func testReconnect_OnReceiveError_TransitionsToReconnecting() async throws {
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(
            taskFactory: { _ in mock },
            heartbeatIntervalSec: 5.0,         // long enough that hb doesn't interfere
            reconnectBaseDelayMs: 5_000        // long enough to observe .reconnecting state
        )
        try await driver.connect(url: url, jwt: "JWT.xx")
        // Inject receive() error → receiveLoop should route through handleConnectionLoss.
        mock.enqueueError(URLError(.networkConnectionLost))
        // Let the loop process + transition state.
        try await Task.sleep(nanoseconds: 150_000_000)
        let s = await driver.state
        if case .reconnecting = s {
            // ok
        } else {
            XCTFail("expected .reconnecting state, got \(s)")
        }
        await driver.disconnect()
    }

    /// When repeated WS failures keep firing, the reconnect machinery keeps
    /// trying — the factory is invoked multiple times. (Within a single
    /// uninterrupted reconnect cycle the `attempt:N` counter grows; once a
    /// reconnect briefly succeeds and then the new WS fails, a fresh cycle
    /// starts at attempt=1. Both the integration property "loop keeps trying"
    /// and the schedule formula are covered separately.)
    func testReconnect_StateTransition_KeepsTryingOnFailure() async throws {
        // Always-failing factory: every reconnect attempt's receive loop dies.
        let counter = AtomicCounter()
        let failingFactory: @Sendable (URLRequest) -> URLSessionWebSocketTaskProtocol = { _ in
            counter.increment()
            let m = MockWebSocketTask()
            // Pre-load an error so receive() in receiveLoop fails on next iteration.
            m.enqueueError(URLError(.networkConnectionLost))
            return m
        }
        let driver = RealtimeWebSocketDriver(
            taskFactory: failingFactory,
            heartbeatIntervalSec: 60.0,
            reconnectBaseDelayMs: 20,
            reconnectMaxDelayMs: 40
        )
        try await driver.connect(url: url, jwt: "JWT.xx")
        // Wait long enough for multiple reconnect cycles to fire.
        try await Task.sleep(nanoseconds: 300_000_000)
        // Factory called at least 3 times (initial connect + 2+ reconnect attempts).
        XCTAssertGreaterThanOrEqual(counter.value, 3, "factory should be called repeatedly across reconnect cycles")
        await driver.disconnect()
    }

    /// A successful reconnect transitions back to .connected (attempt counter
    /// implicitly resets — the loop returns and a future loss starts fresh).
    func testReconnect_SuccessResetsToConnected() async throws {
        // First task: fails on receive (triggers reconnect). Second task: stays open.
        let firstMock = MockWebSocketTask()
        let secondMock = MockWebSocketTask()
        let counter = AtomicCounter()
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
        try await driver.connect(url: url, jwt: "JWT.xx")
        // Trigger loss → reconnect kicks in → second factory call returns secondMock
        // which never errors → attemptReconnect succeeds → state goes back to .connected.
        firstMock.enqueueError(URLError(.networkConnectionLost))
        // Wait for the reconnect attempt to fire (base 20ms backoff + a margin).
        try await Task.sleep(nanoseconds: 200_000_000)
        let s = await driver.state
        XCTAssertEqual(s, .connected, "expected reconnect success to restore .connected")
        XCTAssertGreaterThanOrEqual(counter.value, 2)
        await driver.disconnect()
    }

    /// After reconnecting with a previously-joined workspace channel, the
    /// reconnect attempt re-issues phx_join for that workspace on the new task.
    func testReconnect_RejoinsPriorChannel() async throws {
        let firstMock = MockWebSocketTask()
        let secondMock = MockWebSocketTask()
        let counter = AtomicCounter()
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
        try await driver.connect(url: url, jwt: "JWT.xx")
        try await driver.joinWorkspaceChannel(workspaceID: "wid-rejoin", accessToken: "JWT.xx")
        // Trigger loss → reconnect issues phx_join again on secondMock.
        firstMock.enqueueError(URLError(.networkConnectionLost))
        try await Task.sleep(nanoseconds: 200_000_000)
        let phxJoinOnSecond = secondMock.outgoing.contains { msg in
            guard case .string(let s) = msg else { return false }
            return s.contains("\"event\":\"phx_join\"") && s.contains("workspace-wid-rejoin")
        }
        XCTAssertTrue(phxJoinOnSecond, "expected phx_join re-issued on new WS task after reconnect")
        await driver.disconnect()
    }

    // MARK: - Suspend / Resume

    /// suspend() transitions to .suspended, cancels heartbeat + reconnect, and
    /// closes the WS with normal close code.
    func testSuspend_TransitionsAndCancels() async throws {
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(
            taskFactory: { _ in mock },
            heartbeatIntervalSec: 0.05
        )
        try await driver.connect(url: url, jwt: "JWT.xx")
        try await Task.sleep(nanoseconds: 80_000_000)
        await driver.suspend()
        let s = await driver.state
        XCTAssertEqual(s, .suspended)
        XCTAssertEqual(mock.cancelCode, .normalClosure)
        // No more heartbeats fire after suspend.
        let countAtSuspend = mock.outgoing.filter { msg in
            guard case .string(let s) = msg else { return false }
            return s.contains("\"event\":\"heartbeat\"")
        }.count
        try await Task.sleep(nanoseconds: 200_000_000)
        let countAfter = mock.outgoing.filter { msg in
            guard case .string(let s) = msg else { return false }
            return s.contains("\"event\":\"heartbeat\"")
        }.count
        XCTAssertEqual(countAtSuspend, countAfter, "heartbeat must not fire while suspended")
    }

    /// resume() from .suspended restores the connection: state → .connected,
    /// a new WS task is opened (factory called twice), heartbeat loop alive.
    func testResume_RestoresConnection() async throws {
        let firstMock = MockWebSocketTask()
        let secondMock = MockWebSocketTask()
        let counter = AtomicCounter()
        let factory: @Sendable (URLRequest) -> URLSessionWebSocketTaskProtocol = { _ in
            counter.increment()
            return counter.value == 1 ? firstMock : secondMock
        }
        let driver = RealtimeWebSocketDriver(
            taskFactory: factory,
            heartbeatIntervalSec: 0.05
        )
        try await driver.connect(url: url, jwt: "JWT.xx")
        await driver.suspend()
        let suspended = await driver.state
        XCTAssertEqual(suspended, .suspended)
        try await driver.resume()
        let resumed = await driver.state
        XCTAssertEqual(resumed, .connected)
        XCTAssertEqual(counter.value, 2, "resume must open a new WS task")
        await driver.disconnect()
    }

    /// Resuming without a prior connect() throws .notConnected — nothing to replay.
    func testResume_WithoutPriorConnect_NoOp() async throws {
        let mock = MockWebSocketTask()
        let driver = RealtimeWebSocketDriver(taskFactory: { _ in mock })
        // Never connected → never suspended → resume() is a no-op (guard fails silently).
        try await driver.resume()
        let s = await driver.state
        XCTAssertEqual(s, .disconnected, "resume() without prior connect should remain disconnected")
    }

    // MARK: - Helpers

    /// Thread-safe counter (mirrors the one in RealtimeWebSocketDriverTests).
    final class AtomicCounter: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: 0)
        func increment() { lock.withLock { $0 += 1 } }
        var value: Int { lock.withLock { $0 } }
    }
}
