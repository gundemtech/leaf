// Phase Track-1 D2 — atomic write of event + FTS5 + event_links + offset + presence_state.

import XCTest
import GRDB
@testable import LeafCore

final class DatabaseWriteAndDeriveIntegrationTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-d2-int-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeDB() throws -> LeafCore.Database {
        try LeafCore.Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    private func makeOffset(nowMs: Int64) -> CollectorOffset {
        CollectorOffset(
            collectorID: CollectorID.linearPolling,
            sourceID: "linear:test",
            byteOffset: 0,
            inode: nil,
            size: 0,
            lastModifiedMs: nowMs,
            updatedMs: nowMs
        )
    }

    private func count(_ db: LeafCore.Database, sql: String, args: StatementArguments = StatementArguments()) throws -> Int {
        try db.readSQL { rawDB in
            try Int.fetchOne(rawDB, sql: sql, arguments: args) ?? 0
        }
    }

    func testWrite_IndexesAndLinks_Atomically() throws {
        let db = try makeDB()
        let event = RawEvent(
            timestamp: Date(),
            signalType: .action,
            bundleID: "linear",
            payload: [
                "event_kind": "issue_updated",
                Schema.EventPayloadKeys.body: "Working on LEAF-127"
            ]
        )
        try db.write(event, knownLinearPrefixes: ["LEAF"])

        let eventCount = try count(db, sql: "SELECT COUNT(*) FROM events")
        let ftsCount = try count(db, sql: "SELECT COUNT(*) FROM events_fts")
        let linkCount = try count(db, sql: "SELECT COUNT(*) FROM event_links")

        XCTAssertEqual(eventCount, 1)
        XCTAssertEqual(ftsCount, 1)
        XCTAssertEqual(linkCount, 1)
    }

    func testWriteBatch_AllEventsIndexed() throws {
        let db = try makeDB()
        let mk: (String) -> RawEvent = { body in
            RawEvent(timestamp: Date(), signalType: .action, bundleID: "linear",
                     payload: ["event_kind": "issue_updated",
                               Schema.EventPayloadKeys.body: body])
        }
        try db.write([mk("first"), mk("second"), mk("third")], knownLinearPrefixes: [])
        XCTAssertEqual(try count(db, sql: "SELECT COUNT(*) FROM events"), 3)
        XCTAssertEqual(try count(db, sql: "SELECT COUNT(*) FROM events_fts"), 3)
    }

    func testWriteEventsOffsetAndPresence_FullPipeline() throws {
        let db = try makeDB()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let event = RawEvent(
            timestamp: Date(),
            signalType: .action,
            bundleID: "linear",
            payload: [
                "event_kind": "issue_updated",
                Schema.EventPayloadKeys.body: "fixes LEAF-300"
            ]
        )
        try db.writeEventsOffsetAndPresence(
            [event],
            offset: makeOffset(nowMs: nowMs),
            presence: (provider: .linear, state: ["assigned_count": 1], derivedMode: nil),
            knownLinearPrefixes: ["LEAF"],
            nowMs: nowMs
        )

        XCTAssertEqual(try count(db, sql: "SELECT COUNT(*) FROM events"), 1)
        XCTAssertEqual(try count(db, sql: "SELECT COUNT(*) FROM events_fts"), 1)
        XCTAssertEqual(try count(db, sql: "SELECT COUNT(*) FROM event_links"), 1)
        XCTAssertEqual(try count(db, sql: "SELECT COUNT(*) FROM collector_offsets"), 1)
        XCTAssertEqual(try count(db, sql: "SELECT COUNT(*) FROM presence_state"), 1)
    }

    func testWriteEventsOffsetAndPresence_FailureRollsBackAll() throws {
        let db = try makeDB()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let event = RawEvent(
            timestamp: Date(),
            signalType: .action,
            bundleID: "linear",
            payload: [
                "event_kind": "issue_updated",
                Schema.EventPayloadKeys.body: "would-be LEAF-500"
            ]
        )
        // Inject failure: a non-encodable value (a Date) in presence state — JSONSerialization throws.
        let badPresence: [String: Any] = ["bad_value": Date()]

        XCTAssertThrowsError(try db.writeEventsOffsetAndPresence(
            [event],
            offset: makeOffset(nowMs: nowMs),
            presence: (provider: .linear, state: badPresence, derivedMode: nil),
            knownLinearPrefixes: ["LEAF"],
            nowMs: nowMs
        ))

        // Atomic rollback — no rows in any of the affected tables.
        XCTAssertEqual(try count(db, sql: "SELECT COUNT(*) FROM events"), 0)
        XCTAssertEqual(try count(db, sql: "SELECT COUNT(*) FROM events_fts"), 0)
        XCTAssertEqual(try count(db, sql: "SELECT COUNT(*) FROM event_links"), 0)
    }
}
