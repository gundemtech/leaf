// Phase 2.3 — atomic write API (events insert + offset UPSERT в одной транзакции).
// Это primary write-path для tail-read collector'ов: либо обе записи commit,
// либо ни одной (Agent crash посреди flush → no duplicates + no lost-but-marked).

import XCTest
@testable import LeafCore

final class DatabaseAtomicEventsAndOffsetTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-atomic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Combined write: 5 aiCollaboration events + offset UPSERT → оба видны после.
    /// Round-trip: count events == 5, offset == provided.
    func testAtomicWrite() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let events = (0..<5).map { i in
            RawEvent(
                timestamp: base.addingTimeInterval(TimeInterval(i * 30)),
                signalType: .aiCollaboration,
                bundleID: "com.anthropic.claude-code",
                payload: [
                    "event_kind": "tool_use",
                    "tool_name": "Read",
                    "session_id": "session-A"
                ]
            )
        }
        let offset = CollectorOffset(
            collectorID: CollectorID.claudeCodeJSONL,
            sourceID: "/tmp/session-A.jsonl",
            byteOffset: 1024,
            inode: 555,
            size: 1024,
            lastModifiedMs: 1_700_000_500_000,
            updatedMs: 1_700_000_500_000
        )

        try db.writeEventsAndOffset(events, offset: offset)

        // Events: ровно 5, все signal_type=aiCollaboration.
        let range = DateInterval(
            start: base.addingTimeInterval(-10),
            end: base.addingTimeInterval(86_400)
        )
        let read = try db.events(in: range)
        XCTAssertEqual(read.count, 5)
        XCTAssertTrue(read.allSatisfy { $0.signalType == .aiCollaboration })

        // Offset upsert'ed.
        let stored = try db.readOffset(
            collectorID: CollectorID.claudeCodeJSONL,
            sourceID: "/tmp/session-A.jsonl"
        )
        XCTAssertEqual(stored?.byteOffset, 1024)
        XCTAssertEqual(stored?.size, 1024)
        XCTAssertEqual(stored?.inode, 555)
    }

    /// Edge case: empty events array + offset → только UPSERT, не throws.
    /// Используется в bootstrap branch (skip-backward) когда файл существует
    /// но мы не читаем его исторический контент.
    func testEmptyEventsWithOffsetIsAllowed() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let offset = CollectorOffset(
            collectorID: CollectorID.claudeCodeJSONL,
            sourceID: "/tmp/old-session.jsonl",
            byteOffset: 50_000,
            inode: 999,
            size: 50_000,
            lastModifiedMs: 1_690_000_000_000,
            updatedMs: 1_700_000_000_000
        )

        try db.writeEventsAndOffset([], offset: offset)

        let stored = try db.readOffset(
            collectorID: CollectorID.claudeCodeJSONL,
            sourceID: "/tmp/old-session.jsonl"
        )
        XCTAssertEqual(stored?.byteOffset, 50_000)

        // Никаких events не записалось.
        let allEvents = try db.events(in: DateInterval(
            start: .distantPast,
            end: .distantFuture
        ))
        XCTAssertTrue(allEvents.isEmpty)
    }
}
