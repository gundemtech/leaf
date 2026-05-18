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
