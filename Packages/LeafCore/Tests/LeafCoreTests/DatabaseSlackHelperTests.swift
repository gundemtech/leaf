// Phase 4.4 B6 — Database.readLatestSlackHuddleEvent helper tests.
// Helper picks the latest context-event with source=slack + event_kind=huddle_state_change.
// Filters: action-events, non-slack source, missing huddle event_kind — all skipped.

import XCTest
@testable import LeafCore

final class DatabaseSlackHelperTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-slack-helper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeDB() throws -> Database {
        try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    private func huddleEvent(state: String, atMs: Int64) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(atMs) / 1000.0),
            signalType: .context,
            bundleID: nil,
            payload: [
                "source": "slack",
                "event_kind": "slack_huddle_state_change",
                "state": state
            ]
        )
    }

    func testReadLatestSlackHuddleEvent_NoEvents_ReturnsNil() throws {
        let db = try makeDB()
        XCTAssertNil(try db.readLatestSlackHuddleEvent())
    }

    func testReadLatestSlackHuddleEvent_ReturnsMostRecent() throws {
        let db = try makeDB()
        let older: Int64 = 1_700_000_000_000
        let newer: Int64 = 1_700_000_300_000
        try db.write([
            huddleEvent(state: "default_unset", atMs: older),
            huddleEvent(state: "in_a_huddle", atMs: newer)
        ])

        let summary = try db.readLatestSlackHuddleEvent()
        XCTAssertEqual(summary?.state, "in_a_huddle")
        XCTAssertEqual(summary?.tsMs, newer)
    }

    /// Action-event with source=slack (message aggregate) — skipped even if
    /// it is newer, because the filter requires signal_type=context AND event_kind=huddle_state_change.
    func testReadLatestSlackHuddleEvent_IgnoresNonHuddleEvents() throws {
        let db = try makeDB()
        let huddleMs: Int64 = 1_700_000_000_000
        let actionMs: Int64 = 1_700_000_500_000  // newer but action — should be skipped
        try db.write([
            huddleEvent(state: "default_unset", atMs: huddleMs),
            RawEvent(
                timestamp: Date(timeIntervalSince1970: TimeInterval(actionMs) / 1000.0),
                signalType: .action,
                bundleID: nil,
                payload: [
                    "source": "slack",
                    "event_kind": "slack_message_authored_aggregate",
                    "channel_name": "engineering",
                    "count": "3"
                ]
            )
        ])

        let summary = try db.readLatestSlackHuddleEvent()
        XCTAssertEqual(summary?.state, "default_unset")
        XCTAssertEqual(summary?.tsMs, huddleMs)
    }

    /// A newer Linear context-event of the same type must NOT be returned —
    /// payload.source != "slack" is filtered out.
    func testReadLatestSlackHuddleEvent_IgnoresNonSlackEvents() throws {
        let db = try makeDB()
        let slackMs: Int64 = 1_700_000_000_000
        let linearMs: Int64 = 1_700_000_500_000
        try db.write([
            huddleEvent(state: "in_a_huddle", atMs: slackMs),
            RawEvent(
                timestamp: Date(timeIntervalSince1970: TimeInterval(linearMs) / 1000.0),
                signalType: .context,
                bundleID: nil,
                payload: [
                    "source": "linear",
                    "event_kind": "slack_huddle_state_change",  // even if another provider happens to use the same event_kind
                    "state": "default_unset"
                ]
            )
        ])

        let summary = try db.readLatestSlackHuddleEvent()
        XCTAssertEqual(summary?.state, "in_a_huddle")
        XCTAssertEqual(summary?.tsMs, slackMs)
    }
}
