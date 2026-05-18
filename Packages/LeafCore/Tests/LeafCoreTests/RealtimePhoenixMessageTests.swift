//
//  RealtimePhoenixMessageTests.swift
//  LeafCoreTests
//
//  Track 5 / S7 — Phase D.2 + D.3. Pure-function tests for the Phoenix frame
//  builders + parser used by RealtimeWebSocketDriver.
//

import XCTest
@testable import LeafCore

final class RealtimePhoenixMessageTests: XCTestCase {

    // MARK: - phx_join payload

    func testPhxJoin_TopicFormatIsRealtimeLeafWorkspacePrefix() throws {
        let frame = try RealtimePhoenixFrame.phxJoin(
            workspaceID: "abc123",
            accessToken: "JWT.xxx.yyy",
            ref: "1"
        )
        guard let data = frame.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("frame should be JSON object")
        }
        XCTAssertEqual(obj["topic"] as? String, "realtime:leaf-workspace-abc123")
        XCTAssertEqual(obj["event"] as? String, "phx_join")
        XCTAssertEqual(obj["ref"] as? String, "1")
    }

    func testPhxJoin_PayloadCarriesAccessTokenAndPostgresChangesConfig() throws {
        let frame = try RealtimePhoenixFrame.phxJoin(
            workspaceID: "wid",
            accessToken: "JWT.xxx.yyy",
            ref: "42"
        )
        let data = frame.data(using: .utf8)!
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let payload = obj["payload"] as! [String: Any]
        XCTAssertEqual(payload["access_token"] as? String, "JWT.xxx.yyy")
        let config = payload["config"] as! [String: Any]
        let changes = config["postgres_changes"] as! [[String: Any]]
        XCTAssertEqual(changes.count, 3)
        // INSERT team_events
        XCTAssertEqual(changes[0]["event"] as? String, "INSERT")
        XCTAssertEqual(changes[0]["table"] as? String, "team_events")
        XCTAssertEqual(changes[0]["filter"] as? String, "workspace_id=eq.wid")
        XCTAssertEqual(changes[0]["schema"] as? String, "public")
        // INSERT direct_messages
        XCTAssertEqual(changes[1]["event"] as? String, "INSERT")
        XCTAssertEqual(changes[1]["table"] as? String, "direct_messages")
        // UPDATE direct_messages
        XCTAssertEqual(changes[2]["event"] as? String, "UPDATE")
        XCTAssertEqual(changes[2]["table"] as? String, "direct_messages")
    }

    func testPhxJoin_BroadcastSelfDisabled() throws {
        let frame = try RealtimePhoenixFrame.phxJoin(
            workspaceID: "wid", accessToken: "tok", ref: "1"
        )
        let obj = try JSONSerialization.jsonObject(with: frame.data(using: .utf8)!) as! [String: Any]
        let payload = obj["payload"] as! [String: Any]
        let config = payload["config"] as! [String: Any]
        let broadcast = config["broadcast"] as! [String: Any]
        XCTAssertEqual(broadcast["self"] as? Bool, false)
    }

    // MARK: - phx_leave

    func testPhxLeave_EmptyPayload() throws {
        let frame = try RealtimePhoenixFrame.phxLeave(
            topic: "realtime:leaf-workspace-wid", ref: "5"
        )
        let obj = try JSONSerialization.jsonObject(with: frame.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(obj["topic"] as? String, "realtime:leaf-workspace-wid")
        XCTAssertEqual(obj["event"] as? String, "phx_leave")
        XCTAssertEqual(obj["ref"] as? String, "5")
        let payload = obj["payload"] as! [String: Any]
        XCTAssertTrue(payload.isEmpty)
    }

    // MARK: - Inbound parse

    func testParse_phxReplyOK() throws {
        let json = """
        {"topic":"realtime:leaf-workspace-wid","event":"phx_reply","payload":{"status":"ok","response":{}},"ref":"1"}
        """
        let msg = RealtimePhoenixMessage.parse(json)
        XCTAssertNotNil(msg)
        XCTAssertEqual(msg?.event, "phx_reply")
        XCTAssertEqual(msg?.topic, "realtime:leaf-workspace-wid")
        XCTAssertEqual(msg?.payload["status"] as? String, "ok")
        XCTAssertEqual(msg?.ref, "1")
    }

    func testParse_postgresChangesInsert() throws {
        let json = """
        {"topic":"realtime:leaf-workspace-wid","event":"postgres_changes","payload":{"data":{"type":"INSERT","table":"team_events","record":{"event_id":"ev-1"}}},"ref":null}
        """
        let msg = RealtimePhoenixMessage.parse(json)
        XCTAssertNotNil(msg)
        XCTAssertEqual(msg?.event, "postgres_changes")
        let data = msg?.payload["data"] as? [String: Any]
        XCTAssertEqual(data?["type"] as? String, "INSERT")
        XCTAssertEqual(data?["table"] as? String, "team_events")
    }

    // MARK: - Topic helper

    func testRealtimeTopic_LowercaseWorkspaceID() {
        XCTAssertEqual(
            RealtimeTopic.forWorkspace("abcDEF123"),
            "realtime:leaf-workspace-abcDEF123"
        )
    }
}
