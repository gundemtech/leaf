// Phase Track-4 S4 — FTS indexing for 4 user-authored title/filename payloads
// landed by Track-4 S2/S3 (notes title, zoom meeting topic, screenshot/download
// filenames). Mirrors `EventsFullTextStoreTests` setup pattern.

import GRDB
import XCTest

@testable import LeafCore

final class EventsFullTextStoreTrackFourTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-fts-track4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeDB() throws -> LeafCore.Database {
        try LeafCore.Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    private func insertRawEventRow(_ db: LeafCore.Database, signalType: String, bundleID: String?) throws -> Int64 {
        try db.writeSQL { rawDB in
            try rawDB.execute(
                sql: "INSERT INTO events (ts, signal_type, bundle_id, payload_json) VALUES (?, ?, ?, '{}')",
                arguments: [Int64(Date().timeIntervalSince1970 * 1000), signalType, bundleID]
            )
            return rawDB.lastInsertedRowID
        }
    }

    private func indexAndSearch(
        signalType: String,
        bundleID: String?,
        payload: [String: String],
        query: String
    ) throws -> (bodyKinds: [String], hits: Int) {
        let db = try makeDB()
        let eid = try insertRawEventRow(db, signalType: signalType, bundleID: bundleID)
        try db.writeSQL { rawDB in
            try EventsFullTextStore.indexEvent(
                eventID: eid, signalType: signalType, bundleID: bundleID, payload: payload, in: rawDB
            )
        }
        let bodyKinds: [String] = try db.readSQL { rawDB in
            try Row.fetchAll(
                rawDB,
                sql: "SELECT body_kind FROM events_fts_meta WHERE event_id = ?",
                arguments: [eid]
            ).map { $0["body_kind"] as String? ?? "" }
        }
        let hits: Int = try db.readSQL { rawDB in
            try Int.fetchOne(
                rawDB,
                sql: """
                    SELECT COUNT(*) FROM events_fts
                    JOIN events_fts_meta ON events_fts_meta.fts_rowid = events_fts.rowid
                    WHERE events_fts MATCH ? AND events_fts_meta.event_id = ?
                    """, arguments: [query, eid]) ?? 0
        }
        return (bodyKinds, hits)
    }

    // MARK: - Indexing (Track-4 S4 body-kind dispatch routes 4 new payload keys)

    func testNotesTitleIndexed() throws {
        let result = try indexAndSearch(
            signalType: "attention",
            bundleID: "com.apple.Notes",
            payload: ["event_kind": "notes_active_title_changed", "note_title": "Q1 review"],
            query: "Q1"
        )
        XCTAssertEqual(result.bodyKinds, [Schema.BodyKinds.notesTitle])
        XCTAssertEqual(result.hits, 1)
    }

    func testZoomMeetingNameIndexed() throws {
        let result = try indexAndSearch(
            signalType: "context",
            bundleID: "us.zoom.xos",
            payload: ["event_kind": "zoom_meeting_name_observed", "meeting_topic": "Sprint planning"],
            query: "Sprint"
        )
        XCTAssertEqual(result.bodyKinds, [Schema.BodyKinds.zoomMeetingName])
        XCTAssertEqual(result.hits, 1)
    }

    func testScreenshotFilenameIndexed() throws {
        let result = try indexAndSearch(
            signalType: "content",
            bundleID: nil,
            payload: ["event_kind": "screenshot_taken", "filename": "draft mockup.png"],
            query: "mockup"
        )
        XCTAssertEqual(result.bodyKinds, [Schema.BodyKinds.screenshotFilename])
        XCTAssertEqual(result.hits, 1)
    }

    func testDownloadFilenameIndexed() throws {
        let result = try indexAndSearch(
            signalType: "content",
            bundleID: nil,
            payload: ["event_kind": "download_added", "filename": "report.pdf"],
            query: "report"
        )
        XCTAssertEqual(result.bodyKinds, [Schema.BodyKinds.downloadFilename])
        XCTAssertEqual(result.hits, 1)
    }

    // MARK: - Negative (whitespace / missing key → no FTS row)

    func testNotesTitleWhitespaceOnlyNotIndexed() throws {
        let result = try indexAndSearch(
            signalType: "attention",
            bundleID: "com.apple.Notes",
            payload: ["event_kind": "notes_active_title_changed", "note_title": "   "],
            query: "anything"
        )
        XCTAssertEqual(result.bodyKinds, [])
        XCTAssertEqual(result.hits, 0)
    }

    func testNotesTitleMissingPayloadKeyNotIndexed() throws {
        let result = try indexAndSearch(
            signalType: "attention",
            bundleID: "com.apple.Notes",
            payload: ["event_kind": "notes_active_title_changed"],
            query: "anything"
        )
        XCTAssertEqual(result.bodyKinds, [])
        XCTAssertEqual(result.hits, 0)
    }
}
