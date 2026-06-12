// Phase Track-1 D3 — Commit 7. Handle-dispatch tests for the 3 high-level
// structured MCP tools.
//
// LeafMCP target itself has no SPM test setup (Xcode-only target, see existing
// 12 tool shells), so we exercise the testable substrate that lives in LeafCore:
//
//   1. `D3ToolParams.decode*` — JSON-RPC argument decoding (success + error paths).
//   2. `QueryEngine.{queryActivity, getDecision, currentWork}` end-to-end on a
//      real (test-encrypted) DB — verifies the LeafMCP shells' delegation path
//      exactly as `execute(arguments:)` would call it.
//   3. `D3ResponseEncoder.toDict(_:)` — Codable→[String: Any] bridge that
//      LeafMCP shells use to feed `ToolResponseBuilder.versionedJSONResult`,
//      verifying `schemaVersion` survives the round-trip.

import XCTest
import GRDB
@testable import LeafCore

final class D3ToolHandleTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-d3-handle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func openWriter() throws -> LeafCore.Database {
        try LeafCore.Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    private func makeEngine() -> QueryEngine {
        QueryEngine(
            dbURL: dbURL,
            dbConfig: .weakDefaults,
            dbEncryption: .deterministicTest,
            detectorMoat: .publicSubstrate
        )
    }

    // MARK: - Successful dispatch — verifies tool-shell → engine → encoder path.

    /// Mirrors `QueryActivityTool.execute(arguments:)`: decode period, call engine,
    /// encode response. Asserts the encoder preserves `schemaVersion`.
    func testQueryActivityHandleDispatch() throws {
        let db = try openWriter()
        let event = RawEvent(
            timestamp: Date(timeIntervalSince1970: 1_000),
            signalType: .action,
            bundleID: "com.test",
            payload: ["event_kind": "issue_updated", "issue_key": "LEAF-1"]
        )
        try db.write(event)

        let args: [String: Any] = [
            "period": ["start_ms": 0, "end_ms": 10_000_000]
        ]
        guard case .ok(let (period, filter)) = D3ToolParams.decodeQueryActivity(arguments: args) else {
            return XCTFail("decode failed")
        }
        XCTAssertEqual(period.startMs, 0)
        XCTAssertEqual(period.endMs, 10_000_000)
        XCTAssertNil(filter)

        let response = try makeEngine().queryActivity(period: period, filter: filter)
        let dict = try D3ResponseEncoder.toDict(response)
        XCTAssertEqual(dict["schemaVersion"] as? String, "1.0")
        XCTAssertNotNil(dict["events"])
    }

    /// Mirrors `GetDecisionTool.execute(arguments:)`: decode topic, call engine,
    /// encode response. Empty DB → `decision == nil` but envelope still encodes.
    func testGetDecisionHandleDispatch() throws {
        // Create empty DB so engine has tables but no events.
        _ = try openWriter()

        let args: [String: Any] = ["topic": "rate limiter"]
        guard case .ok(let (topic, period, limit)) = D3ToolParams.decodeGetDecision(arguments: args) else {
            return XCTFail("decode failed")
        }
        XCTAssertEqual(topic, "rate limiter")
        XCTAssertNil(period)
        XCTAssertEqual(limit, 1, "limit defaults to 1 (back-compat top-1)")

        let response = try makeEngine().getDecision(topic: topic, period: period)
        let dict = try D3ResponseEncoder.toDict(response)
        XCTAssertEqual(dict["schemaVersion"] as? String, "1.0")
        // `decision` field is Codable optional → encodes as NSNull (not absent).
        // Either NSNull or absent would be acceptable; we assert the envelope shape.
        XCTAssertNotNil(dict["relatedEvents"])
    }

    /// Mirrors `CurrentWorkTool.execute(arguments:)`: optional now_ms override,
    /// call engine, encode response. No required args → empty dict OK.
    func testCurrentWorkHandleDispatch() throws {
        _ = try openWriter()

        // Empty arguments — caller path with no override (production default).
        guard case .ok(let nilOverride) = D3ToolParams.decodeCurrentWork(arguments: nil) else {
            return XCTFail("decode failed for nil arguments")
        }
        XCTAssertNil(nilOverride)

        // Explicit override path — used by tests + future deterministic clients.
        let args: [String: Any] = ["now_ms": 12_345_678]
        guard case .ok(let override) = D3ToolParams.decodeCurrentWork(arguments: args) else {
            return XCTFail("decode failed for override")
        }
        XCTAssertEqual(override, 12_345_678)

        let response = try makeEngine().currentWork(nowMs: override ?? 0)
        let dict = try D3ResponseEncoder.toDict(response)
        XCTAssertEqual(dict["schemaVersion"] as? String, "1.0")
    }

    // MARK: - Param decode errors — exact messages flow into MCPProtocolError.invalidParams.

    func testParamDecodeErrors_QueryActivity() {
        // Missing period entirely.
        if case .error(let m1) = D3ToolParams.decodeQueryActivity(arguments: [:] as [String: Any]) {
            XCTAssertTrue(m1.contains("period"), m1)
        } else {
            XCTFail("expected error for missing period")
        }

        // period present but missing start_ms/end_ms.
        let args: [String: Any] = ["period": ["start_ms": 1] as [String: Any]]
        if case .error(let m2) = D3ToolParams.decodeQueryActivity(arguments: args) {
            XCTAssertTrue(m2.contains("integers"), m2)
        } else {
            XCTFail("expected error for partial period")
        }

        // arguments isn't even a dict.
        if case .error = D3ToolParams.decodeQueryActivity(arguments: "not a dict") {
            // ok
        } else {
            XCTFail("expected error for non-dict args")
        }
    }

    func testParamDecodeErrors_GetDecision() {
        // Missing topic.
        if case .error(let m1) = D3ToolParams.decodeGetDecision(arguments: [:] as [String: Any]) {
            XCTAssertTrue(m1.contains("topic"), m1)
        } else {
            XCTFail("expected error for missing topic")
        }

        // Empty topic string.
        if case .error = D3ToolParams.decodeGetDecision(arguments: ["topic": ""] as [String: Any]) {
            // ok
        } else {
            XCTFail("expected error for empty topic")
        }

        // Topic OK but malformed period present.
        let args: [String: Any] = ["topic": "x", "period": ["start_ms": "not-int"] as [String: Any]]
        if case .error(let m3) = D3ToolParams.decodeGetDecision(arguments: args) {
            XCTAssertTrue(m3.contains("integers"), m3)
        } else {
            XCTFail("expected error for malformed period")
        }
    }

    /// Round-trip the `CurrentWorkResponse` dict back into the typed struct and
    /// verify `schemaVersion` survives. This guards against future Codable
    /// renames that would silently drop the version stamp in production output.
    func testJSONEncodingPreservesSchemaVersion() throws {
        let original = CurrentWorkResponse(
            currentApp: "com.example",
            currentBranch: nil,
            currentFile: nil,
            inProgressLinearTicket: nil,
            lastCommit: nil,
            currentOpenQuestions: [],
            currentBlockers: [],
            whereStopped: nil
        )
        XCTAssertEqual(original.schemaVersion, "1.0")

        let dict = try D3ResponseEncoder.toDict(original)
        XCTAssertEqual(dict["schemaVersion"] as? String, "1.0")

        // Round-trip through JSONSerialization → Codable.
        let data = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(CurrentWorkResponse.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, "1.0")
        XCTAssertEqual(decoded.currentApp, "com.example")
    }
}
