import XCTest
@testable import LeafCore

final class DatabaseIntegrationTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testWriteThenReadSingleEvent() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults)

        let event = RawEvent(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            signalType: .attention,
            bundleID: "com.apple.Xcode",
            payload: ["window": "main"]
        )
        try db.write(event)

        let range = DateInterval(
            start: Date(timeIntervalSince1970: 1_699_000_000),
            end: Date(timeIntervalSince1970: 1_701_000_000)
        )
        let read = try db.events(in: range)
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read[0].signalType, .attention)
        XCTAssertEqual(read[0].bundleID, "com.apple.Xcode")
        XCTAssertEqual(read[0].payload["window"], "main")
    }

    func testBulkWriteAndRangeFilter() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults)

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let events = (0..<50).map { i in
            RawEvent(
                timestamp: base.addingTimeInterval(TimeInterval(i * 60)),
                signalType: .attention,
                bundleID: "com.app.\(i % 3)",
                payload: [:]
            )
        }
        try db.write(events)

        XCTAssertEqual(try db.eventCount(in: DateInterval(start: base, end: base.addingTimeInterval(3600))), 50)

        // Narrow range
        let narrow = DateInterval(start: base, end: base.addingTimeInterval(600))
        XCTAssertEqual(try db.eventCount(in: narrow), 10)

        // Bundle filter
        let filtered = try db.events(in: DateInterval(start: base, end: base.addingTimeInterval(3600)), bundleID: "com.app.1")
        XCTAssertEqual(filtered.count, 17) // indices 1, 4, 7, ..., 49 → 17 items
        XCTAssertTrue(filtered.allSatisfy { $0.bundleID == "com.app.1" })
    }

    func testOrderingAscending() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults)

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // Write in reversed order
        try db.write((0..<5).reversed().map { i in
            RawEvent(timestamp: base.addingTimeInterval(TimeInterval(i * 60)), signalType: .attention, bundleID: "X")
        })

        let read = try db.events(in: DateInterval(start: base, end: base.addingTimeInterval(3600)))
        let timestamps = read.map(\.timestamp.timeIntervalSince1970)
        XCTAssertEqual(timestamps, timestamps.sorted())
    }

    func testReaderCannotWrite() throws {
        // Writer initialises the DB
        _ = try Database.openForWrite(at: dbURL, config: .weakDefaults)

        let reader = try Database.openForRead(at: dbURL, config: .weakDefaults)
        XCTAssertThrowsError(try reader.write(RawEvent(signalType: .attention, bundleID: "X"))) { error in
            guard let lcError = error as? LeafError else {
                return XCTFail("Expected LeafError, got \(error)")
            }
            XCTAssertEqual(lcError, .databaseUnavailable)
        }
    }

    func testReaderSeesWriterWrites() throws {
        let writer = try Database.openForWrite(at: dbURL, config: .weakDefaults)
        let reader = try Database.openForRead(at: dbURL, config: .weakDefaults)

        let ts = Date(timeIntervalSince1970: 1_700_000_000)
        try writer.write(RawEvent(timestamp: ts, signalType: .context, bundleID: nil, payload: ["state": "idle"]))

        let range = DateInterval(start: ts.addingTimeInterval(-10), end: ts.addingTimeInterval(10))
        let read = try reader.events(in: range)
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read[0].signalType, .context)
        XCTAssertEqual(read[0].payload["state"], "idle")
    }

    func testCheckpointWALDoesNotCrash() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults)
        try db.write(RawEvent(signalType: .attention, bundleID: "Z"))
        try db.checkpointWAL()
    }
}

extension LeafError: Equatable {
    public static func == (lhs: LeafError, rhs: LeafError) -> Bool {
        switch (lhs, rhs) {
        case (.notImplemented, .notImplemented): return true
        case (.databaseUnavailable, .databaseUnavailable): return true
        case (.corruptedEnvelope, .corruptedEnvelope): return true
        case (.invalidPayload, .invalidPayload): return true
        case (.keychainUnavailable(let a), .keychainUnavailable(let b)): return a == b
        default: return false
        }
    }
}
