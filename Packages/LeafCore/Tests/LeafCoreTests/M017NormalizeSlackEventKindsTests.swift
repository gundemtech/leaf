import XCTest

import class GRDB.Row

@testable import LeafCore

/// Phase Track-3 D3 — M017 retroactive rename of pre-D3 Slack event_kinds.
/// Verifies the rename helper is idempotent, scoped to the 2 documented
/// mappings, leaves already-prefixed Slack baseline kinds alone, and preserves
/// other payload keys.
final class M017NormalizeSlackEventKindsTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-m017-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    private func openDB() throws -> Database {
        try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    /// Inserts a single event row by raw SQL with payload `{"event_kind":"<kind>"}`
    /// plus optional extra keys. Bypasses high-level helpers so the test can
    /// pre-seed the *old* event_kind names that no longer exist in the codebase.
    private func insertRawEvent(
        _ db: Database,
        kind: String,
        signalType: String = "action",
        bundleID: String? = "com.example.test",
        tsMs: Int64 = 1_700_000_000_000,
        extraKeys: [String: String] = [:]
    ) throws {
        var payload: [String: String] = ["event_kind": kind]
        for (k, v) in extraKeys { payload[k] = v }
        let payloadJSON =
            try String(
                data: JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
                encoding: .utf8
            ) ?? "{}"
        try db.writeSQL { raw in
            try raw.execute(
                sql: """
                    INSERT INTO events (ts, signal_type, bundle_id, payload_json)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [tsMs, signalType, bundleID, payloadJSON]
            )
        }
    }

    private func eventKinds(_ db: Database) throws -> [String] {
        try db.readSQL { raw in
            let rows = try Row.fetchAll(
                raw,
                sql: "SELECT json_extract(payload_json, '$.event_kind') AS k FROM events ORDER BY id ASC"
            )
            return rows.compactMap { $0["k"] as String? }
        }
    }

    private func runRename(_ db: Database) throws {
        try db.writeSQL { raw in
            try M017NormalizeSlackEventKinds.runRename(in: raw)
        }
    }

    // MARK: - Tests

    func testRenamesBothSlackPrefixlessEventKinds() throws {
        let db = try openDB()
        var ts: Int64 = 1_700_000_000_000
        for (old, _) in M017NormalizeSlackEventKinds.renameMap {
            try insertRawEvent(db, kind: old, tsMs: ts)
            ts += 1
        }
        try runRename(db)
        let kinds = try eventKinds(db)
        XCTAssertEqual(kinds.count, M017NormalizeSlackEventKinds.renameMap.count)
        let expected = M017NormalizeSlackEventKinds.renameMap.map { $0.new }
        XCTAssertEqual(
            kinds, expected, "Each old name should be renamed to its mapped slack_* counterpart in insertion order")
        for k in kinds {
            XCTAssertTrue(k.hasPrefix("slack_"), "Renamed kind \(k) should carry slack_* prefix")
        }
        XCTAssertEqual(Set(kinds).count, kinds.count, "Renamed kinds should remain unique")
    }

    func testIdempotent() throws {
        let db = try openDB()
        try insertRawEvent(db, kind: "message_authored_aggregate")
        try runRename(db)
        try runRename(db)
        let kinds = try eventKinds(db)
        XCTAssertEqual(kinds, ["slack_message_authored_aggregate"])
        XCTAssertEqual(kinds.filter { $0 == "slack_message_authored_aggregate" }.count, 1)
    }

    func testAlreadyPrefixedSlackEventsUntouched() throws {
        let db = try openDB()
        // The 6 already-prefixed Slack baseline kinds — M017 must NOT touch.
        let preserved = [
            "slack_thread_reply_aggregate",
            "slack_status_change",
            "slack_presence_state",
            "slack_dnd_state",
            "slack_mention_received_aggregate",
            "slack_file_uploaded_aggregate",
        ]
        var ts: Int64 = 1_700_000_000_000
        for k in preserved {
            try insertRawEvent(db, kind: k, tsMs: ts)
            ts += 1
        }
        try runRename(db)
        let kinds = try eventKinds(db)
        XCTAssertEqual(kinds, preserved, "Already-prefixed Slack entries must be preserved untouched")
    }

    func testNonSlackEventsUntouched() throws {
        let db = try openDB()
        try insertRawEvent(db, kind: "gh_commit_pushed")
        try runRename(db)
        let kinds = try eventKinds(db)
        XCTAssertEqual(kinds, ["gh_commit_pushed"])
    }

    func testEmptyEventsTableIsNoOp() throws {
        let db = try openDB()
        XCTAssertNoThrow(try runRename(db))
        let kinds = try eventKinds(db)
        XCTAssertTrue(kinds.isEmpty)
    }

    func testPayloadOtherKeysPreserved() throws {
        let db = try openDB()
        try insertRawEvent(
            db,
            kind: "huddle_state_change",
            extraKeys: ["channel": "C123", "state": "active"]
        )
        try runRename(db)
        try db.readSQL { raw in
            let row = try Row.fetchOne(raw, sql: "SELECT payload_json FROM events LIMIT 1")
            XCTAssertNotNil(row)
            let payloadJSON = (row?["payload_json"] as String?) ?? ""
            guard let data = payloadJSON.data(using: .utf8),
                let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                XCTFail("payload_json should parse as JSON object")
                return
            }
            XCTAssertEqual(obj["event_kind"] as? String, "slack_huddle_state_change")
            XCTAssertEqual(obj["channel"] as? String, "C123")
            XCTAssertEqual(obj["state"] as? String, "active")
        }
    }
}
