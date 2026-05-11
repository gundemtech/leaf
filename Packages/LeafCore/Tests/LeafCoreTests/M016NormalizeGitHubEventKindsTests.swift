import XCTest
import class GRDB.Row
@testable import LeafCore

/// Phase Track-3 D2 — M016 retroactive rename of pre-D2 GitHub event_kinds.
/// Verifies the rename helper is idempotent, scoped to the 21 documented
/// mappings, and preserves other payload keys.
final class M016NormalizeGitHubEventKindsTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-m016-\(UUID().uuidString)", isDirectory: true)
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
        let payloadJSON = try String(
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
            try M016NormalizeGitHubEventKinds.runRename(in: raw)
        }
    }

    // MARK: - Tests

    func testRenamesAllKnownGitHubEventKindsToGhPrefix() throws {
        let db = try openDB()
        // Seed one row per old name.
        var ts: Int64 = 1_700_000_000_000
        for (old, _) in M016NormalizeGitHubEventKinds.renameMap {
            try insertRawEvent(db, kind: old, tsMs: ts)
            ts += 1
        }
        try runRename(db)
        let kinds = try eventKinds(db)
        XCTAssertEqual(kinds.count, M016NormalizeGitHubEventKinds.renameMap.count)
        let expected = M016NormalizeGitHubEventKinds.renameMap.map { $0.new }
        XCTAssertEqual(kinds, expected, "Each old name should be renamed to its mapped gh_* counterpart in insertion order")
        for k in kinds {
            XCTAssertTrue(k.hasPrefix("gh_"), "Renamed kind \(k) should carry gh_* prefix")
        }
        XCTAssertEqual(Set(kinds).count, kinds.count, "Renamed kinds should remain unique")
    }

    func testIdempotent() throws {
        let db = try openDB()
        try insertRawEvent(db, kind: "pr_opened")
        try runRename(db)
        try runRename(db)
        let kinds = try eventKinds(db)
        XCTAssertEqual(kinds, ["gh_pr_opened"])
        XCTAssertEqual(kinds.filter { $0 == "gh_pr_opened" }.count, 1)
    }

    func testNonGitHubEventsUntouched() throws {
        let db = try openDB()
        try insertRawEvent(db, kind: "linear_issue_updated")
        try runRename(db)
        let kinds = try eventKinds(db)
        XCTAssertEqual(kinds, ["linear_issue_updated"])
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
            kind: "pr_opened",
            extraKeys: ["repo": "owner/repo", "title": "Add feature X"]
        )
        try runRename(db)
        try db.readSQL { raw in
            let row = try Row.fetchOne(raw, sql: "SELECT payload_json FROM events LIMIT 1")
            XCTAssertNotNil(row)
            let payloadJSON = (row?["payload_json"] as String?) ?? ""
            guard let data = payloadJSON.data(using: .utf8),
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                XCTFail("payload_json should parse as JSON object")
                return
            }
            XCTAssertEqual(obj["event_kind"] as? String, "gh_pr_opened")
            XCTAssertEqual(obj["repo"] as? String, "owner/repo")
            XCTAssertEqual(obj["title"] as? String, "Add feature X")
        }
    }
}
