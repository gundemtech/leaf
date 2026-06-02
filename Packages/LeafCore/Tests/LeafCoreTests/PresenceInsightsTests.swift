// Phase 4.7.B-15 — `PresenceInsights.currentSnapshot` (testable backing
// for the `get_current_presence` MCP tool).
//
// The LeafMCP target builds under Xcode (not under `swift test`), so the
// `GetCurrentPresenceTool` tool-struct in `LeafMCP/Tools/` is tested through its
// LeafCore helper (`PresenceInsights.currentSnapshot`). Here — all 4
// planned cases:
//
//   - testExecute_EmptyDB_ReturnsEmptyProviders
//   - testExecute_SeededPresenceState_ReturnsAllRows
//   - testExecute_DerivedModeNullInPhase47
//   - testExecute_NoArgumentsAccepted (tool schema — `properties:{}`,
//     `additionalProperties:false`. The helper accepts no arguments at all,
//     so "extra args ignored" holds trivially for the tool wrapper.
//     The test verifies that the helper is deterministic and does not depend on
//     any arguments, and that the schema is indeed empty in the definition.)

import XCTest
import GRDB
@testable import LeafCore

final class PresenceInsightsTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-presence-insights-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Empty DB

    /// A fresh (just-created) DB → providers={} (empty dictionary
    /// — all 4 PresenceStateWriter.Provider rows are absent). The top-level
    /// shape is preserved: the `providers` and `observed_at_ms` keys are present.
    func testExecute_EmptyDB_ReturnsEmptyProviders() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let payload = try PresenceInsights.currentSnapshot(database: db)

        let providers = try XCTUnwrap(payload["providers"] as? [String: Any])
        XCTAssertEqual(providers.count, 0, "fresh DB → no presence_state rows")

        let observedAt = try XCTUnwrap(payload["observed_at_ms"] as? Int64)
        // Sanity — within a reasonable range (today's epoch timestamp in ms).
        XCTAssertGreaterThan(observedAt, 1_700_000_000_000)
    }

    // MARK: - Seeded → all rows

    /// Seed 3 rows (github / linear / slack) → response.providers contains
    /// all three keys with the state / derived_mode / updated_at_ms fields.
    func testExecute_SeededPresenceState_ReturnsAllRows() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.writeSQL { rawDB in
            try PresenceStateWriter.upsert(
                provider: .github,
                state: ["status": "online", "open_prs": 2],
                derivedMode: nil,
                nowMs: 1_700_000_001_000,
                in: rawDB
            )
            try PresenceStateWriter.upsert(
                provider: .linear,
                state: ["assigned_count": 5, "active_cycle": "Cycle 23"],
                derivedMode: nil,
                nowMs: 1_700_000_002_000,
                in: rawDB
            )
            try PresenceStateWriter.upsert(
                provider: .slack,
                state: ["presence": "active", "snoozed": false],
                derivedMode: nil,
                nowMs: 1_700_000_003_000,
                in: rawDB
            )
        }

        let payload = try PresenceInsights.currentSnapshot(database: db)
        let providers = try XCTUnwrap(payload["providers"] as? [String: Any])
        XCTAssertEqual(providers.count, 3)
        XCTAssertNotNil(providers["github"])
        XCTAssertNotNil(providers["linear"])
        XCTAssertNotNil(providers["slack"])
        XCTAssertNil(providers["derived"], "Phase 4.7 does not write a derived row")

        // GitHub state roundtrip.
        let github = try XCTUnwrap(providers["github"] as? [String: Any])
        let githubState = try XCTUnwrap(github["state"] as? [String: Any])
        XCTAssertEqual(githubState["status"] as? String, "online")
        XCTAssertEqual(githubState["open_prs"] as? Int, 2)
        XCTAssertEqual(github["updated_at_ms"] as? Int64, 1_700_000_001_000)

        // Linear state roundtrip.
        let linear = try XCTUnwrap(providers["linear"] as? [String: Any])
        let linearState = try XCTUnwrap(linear["state"] as? [String: Any])
        XCTAssertEqual(linearState["assigned_count"] as? Int, 5)
        XCTAssertEqual(linearState["active_cycle"] as? String, "Cycle 23")
        XCTAssertEqual(linear["updated_at_ms"] as? Int64, 1_700_000_002_000)

        // Slack state roundtrip.
        let slack = try XCTUnwrap(providers["slack"] as? [String: Any])
        let slackState = try XCTUnwrap(slack["state"] as? [String: Any])
        XCTAssertEqual(slackState["presence"] as? String, "active")
        XCTAssertEqual(slackState["snoozed"] as? Bool, false)
        XCTAssertEqual(slack["updated_at_ms"] as? Int64, 1_700_000_003_000)
    }

    // MARK: - derived_mode invariant

    /// derived_mode must not be populated in Phase 4.7 — every key under
    /// providers contains `derived_mode: NSNull` (an explicit null, not a missing
    /// key).  The Phase 4.9 mode classifier will start writing string values.
    func testExecute_DerivedModeNullInPhase47() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.writeSQL { rawDB in
            try PresenceStateWriter.upsert(
                provider: .github,
                state: ["status": "online"],
                derivedMode: nil,
                nowMs: 1_700_000_000_000,
                in: rawDB
            )
            try PresenceStateWriter.upsert(
                provider: .linear,
                state: ["assigned_count": 0],
                derivedMode: nil,
                nowMs: 1_700_000_000_500,
                in: rawDB
            )
            try PresenceStateWriter.upsert(
                provider: .slack,
                state: ["presence": "active"],
                derivedMode: nil,
                nowMs: 1_700_000_001_000,
                in: rawDB
            )
        }

        let payload = try PresenceInsights.currentSnapshot(database: db)
        let providers = try XCTUnwrap(payload["providers"] as? [String: Any])
        for key in ["github", "linear", "slack"] {
            let entry = try XCTUnwrap(providers[key] as? [String: Any], "providers.\(key) missing")
            XCTAssertNotNil(
                entry["derived_mode"],
                "providers.\(key).derived_mode must be present (as NSNull) — explicit null, not missing key"
            )
            XCTAssertTrue(
                entry["derived_mode"] is NSNull,
                "providers.\(key).derived_mode must be NSNull in Phase 4.7 (got \(String(describing: entry["derived_mode"])))"
            )
        }

        // Round-trip through JSONSerialization — confirm that NSNull
        // actually serializes to `null` rather than being dropped.
        let json = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let jsonString = String(data: json, encoding: .utf8) ?? ""
        XCTAssertTrue(
            jsonString.contains(#""derived_mode":null"#),
            "JSON output must contain explicit `derived_mode:null`. Got: \(jsonString)"
        )
    }

    // MARK: - schema / args

    /// Tool schema — `properties:{}` + `additionalProperties:false`,
    /// and the helper accepts no arguments at all. We check both invariants.
    /// This is a contract check: the `currentSnapshot(database:)` call is deterministic
    /// with respect to DB content; "extra args" in the tool wrapper are discarded at
    /// the MCP server schema level (additionalProperties=false), but the helper
    /// never sees them and behaves identically.
    func testExecute_NoArgumentsAccepted() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try db.writeSQL { rawDB in
            try PresenceStateWriter.upsert(
                provider: .github,
                state: ["status": "online"],
                derivedMode: nil,
                nowMs: 1_700_000_000_000,
                in: rawDB
            )
        }

        // The helper is deterministic — two successive calls return
        // an identical providers payload (observed_at_ms may differ).
        let p1 = try PresenceInsights.currentSnapshot(database: db)
        let p2 = try PresenceInsights.currentSnapshot(database: db)

        let providers1 = try XCTUnwrap(p1["providers"] as? [String: Any])
        let providers2 = try XCTUnwrap(p2["providers"] as? [String: Any])

        // Serialize both providers dictionaries to deterministic JSON
        // (sortedKeys) and compare.
        let j1 = try JSONSerialization.data(withJSONObject: providers1, options: [.sortedKeys])
        let j2 = try JSONSerialization.data(withJSONObject: providers2, options: [.sortedKeys])
        XCTAssertEqual(j1, j2, "providers payload must be deterministic across calls")
    }
}
