// Phase Track-6 P5 — PresenceStateWriter `.zoom` provider case + state builder.
// Asserts:
//   1. Provider.zoom exists with canonical raw value "zoom"
//   2. buildZoomState shapes match spec §8.2 (transient fields gated by meeting_active)
//   3. Round-trip through upsert/read preserves JSON shape
//   4. ADR-010 walkback: no raw URLs / titles / participants in stored state

import XCTest
import GRDB
@testable import LeafCore

final class PresenceStateWriterZoomTests: XCTestCase {

    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-zoom-presence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeDB() throws -> LeafCore.Database {
        try LeafCore.Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    // MARK: - Provider enum

    func testZoomProviderRawValue() {
        XCTAssertEqual(PresenceStateWriter.Provider.zoom.rawValue, "zoom")
    }

    func testProviderAllCasesIncludesZoom() {
        XCTAssertTrue(PresenceStateWriter.Provider.allCases.contains(.zoom))
    }

    // MARK: - buildZoomState shape

    func testBuildZoomStateActiveAllFields() {
        let state = PresenceStateWriter.buildZoomState(
            meetingActive: true,
            meetingStartedAtMs: 1_715_882_400_000,
            coldStart: false,
            linkedCalendarEventID: "deadbeefcafef00d",
            lastObservedAtMs: 1_715_882_430_000
        )
        XCTAssertEqual(state["meeting_active"] as? Bool, true)
        XCTAssertEqual(state["meeting_started_at_ms"] as? Int64, 1_715_882_400_000)
        XCTAssertEqual(state["cold_start"] as? Bool, false)
        XCTAssertEqual(state["linked_calendar_event_id"] as? String, "deadbeefcafef00d")
        XCTAssertEqual(state["last_observed_at_ms"] as? Int64, 1_715_882_430_000)
    }

    func testBuildZoomStateInactiveOmitsTransient() {
        let state = PresenceStateWriter.buildZoomState(
            meetingActive: false,
            meetingStartedAtMs: nil,
            coldStart: nil,
            linkedCalendarEventID: nil,
            lastObservedAtMs: 1_715_882_430_000
        )
        XCTAssertEqual(state["meeting_active"] as? Bool, false)
        XCTAssertNil(state["meeting_started_at_ms"])
        XCTAssertNil(state["cold_start"])
        XCTAssertNil(state["linked_calendar_event_id"])
        XCTAssertEqual(state["last_observed_at_ms"] as? Int64, 1_715_882_430_000)
    }

    func testBuildZoomStateActiveButNoCalendarMatchOmitsLinkedID() {
        let state = PresenceStateWriter.buildZoomState(
            meetingActive: true,
            meetingStartedAtMs: 1000,
            coldStart: true,
            linkedCalendarEventID: nil,
            lastObservedAtMs: 1100
        )
        XCTAssertEqual(state["meeting_active"] as? Bool, true)
        XCTAssertEqual(state["meeting_started_at_ms"] as? Int64, 1000)
        XCTAssertEqual(state["cold_start"] as? Bool, true)
        XCTAssertNil(state["linked_calendar_event_id"])
    }

    func testBuildZoomStateActiveWithEmptyLinkedIDOmitted() {
        // Defense: empty string treated as "no match" (not stored).
        let state = PresenceStateWriter.buildZoomState(
            meetingActive: true,
            meetingStartedAtMs: 1000,
            coldStart: false,
            linkedCalendarEventID: "",
            lastObservedAtMs: 1100
        )
        XCTAssertNil(state["linked_calendar_event_id"])
    }

    // MARK: - Round-trip

    func testRoundTripActiveStateThroughDB() throws {
        let db = try makeDB()
        let state = PresenceStateWriter.buildZoomState(
            meetingActive: true,
            meetingStartedAtMs: 1_715_882_400_000,
            coldStart: false,
            linkedCalendarEventID: "abc123def456abcd",
            lastObservedAtMs: 1_715_882_430_000
        )
        try db.writeSQL { rawDB in
            try PresenceStateWriter.upsert(provider: .zoom, state: state, nowMs: 1_715_882_430_000, in: rawDB)
        }
        let read = try db.readSQL { rawDB in
            try PresenceStateWriter.read(provider: .zoom, in: rawDB)
        }
        XCTAssertNotNil(read)
        XCTAssertEqual(read?.state["meeting_active"] as? Bool, true)
        XCTAssertEqual(read?.state["meeting_started_at_ms"] as? Int64, 1_715_882_400_000)
        XCTAssertEqual(read?.state["linked_calendar_event_id"] as? String, "abc123def456abcd")
        XCTAssertEqual(read?.updatedAtMs, 1_715_882_430_000)
        XCTAssertNil(read?.derivedMode)  // P5 doesn't populate derivedMode
    }

    func testIdempotentUpsertReplaces() throws {
        let db = try makeDB()
        let firstState = PresenceStateWriter.buildZoomState(
            meetingActive: false, meetingStartedAtMs: nil, coldStart: nil,
            linkedCalendarEventID: nil, lastObservedAtMs: 1000
        )
        let secondState = PresenceStateWriter.buildZoomState(
            meetingActive: true, meetingStartedAtMs: 2000, coldStart: false,
            linkedCalendarEventID: "newhash", lastObservedAtMs: 2100
        )
        try db.writeSQL { rawDB in
            try PresenceStateWriter.upsert(provider: .zoom, state: firstState, nowMs: 1000, in: rawDB)
            try PresenceStateWriter.upsert(provider: .zoom, state: secondState, nowMs: 2100, in: rawDB)
        }
        let read = try db.readSQL { rawDB in
            try PresenceStateWriter.read(provider: .zoom, in: rawDB)
        }
        XCTAssertEqual(read?.state["meeting_active"] as? Bool, true)
        XCTAssertEqual(read?.state["meeting_started_at_ms"] as? Int64, 2000)
        XCTAssertEqual(read?.updatedAtMs, 2100)
    }

    // MARK: - ADR-010 walkback

    func testStateBuilderRefusesRawURLOrTitleByOmission() {
        // buildZoomState only accepts the parameters defined in the API.
        // Compile-time guarantee that callers cannot pass meeting_title / raw_url etc.
        // through this builder. Caller-side discipline still required if they bypass
        // the builder and pass raw [String: Any] to upsert — separate sentinel test
        // in RelayBodyLeakageTests covers that path.
        let state = PresenceStateWriter.buildZoomState(
            meetingActive: true,
            meetingStartedAtMs: 1000,
            coldStart: false,
            linkedCalendarEventID: "hash",
            lastObservedAtMs: 1100
        )
        // Only documented keys present.
        let allowedKeys: Set<String> = [
            "meeting_active",
            "meeting_started_at_ms",
            "cold_start",
            "linked_calendar_event_id",
            "last_observed_at_ms"
        ]
        XCTAssertEqual(Set(state.keys), allowedKeys.intersection(state.keys))
        let unexpectedKeys = Set(state.keys).subtracting(allowedKeys)
        XCTAssertTrue(unexpectedKeys.isEmpty,
                      "buildZoomState emitted unexpected keys: \(unexpectedKeys)")
    }
}
