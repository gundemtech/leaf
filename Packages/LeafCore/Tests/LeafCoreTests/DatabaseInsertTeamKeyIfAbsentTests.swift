import XCTest
@testable import LeafCore

final class DatabaseInsertTeamKeyIfAbsentTests: XCTestCase {

    private var tempDir: URL!
    private var dbURL: URL!
    private var db: LeafCore.Database!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-insertifabsent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
        db = try LeafCore.Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    override func tearDown() async throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeKey(id: String, generatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
                         deprecated: Bool = false, by: String = "self-mem") -> TeamKey {
        TeamKey(
            id: id, generatedAt: generatedAt,
            deprecatedAt: deprecated ? Date(timeIntervalSince1970: 1_700_000_001) : nil,
            generatedByMemberID: by
        )
    }

    func testHappyPath_InsertsRow() throws {
        try db.insertTeamKeyIfAbsent(makeKey(id: "key-1"))
        let read = try db.readTeamKey(byID: "key-1")
        XCTAssertEqual(read?.id, "key-1")
        XCTAssertNil(read?.deprecatedAt)
    }

    func testDuplicateID_NoOpPreservesFirstRow() throws {
        let first = makeKey(id: "key-1", generatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = makeKey(id: "key-1", generatedAt: Date(timeIntervalSince1970: 1_700_000_500), deprecated: true)
        try db.insertTeamKeyIfAbsent(first)
        try db.insertTeamKeyIfAbsent(second)
        let read = try db.readTeamKey(byID: "key-1")
        XCTAssertNotNil(read)
        XCTAssertEqual(
            Int64(read!.generatedAt.timeIntervalSince1970 * 1000),
            1_700_000_000_000
        )
        XCTAssertNil(read?.deprecatedAt, "Second insert with deprecatedAt=set must not overwrite")
    }

    func testReaderModeThrowsDatabaseUnavailable() throws {
        let readerDB = try LeafCore.Database.openForRead(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        XCTAssertThrowsError(try readerDB.insertTeamKeyIfAbsent(makeKey(id: "key-1"))) { err in
            guard case LeafError.databaseUnavailable = err else {
                XCTFail("expected .databaseUnavailable, got \(err)")
                return
            }
        }
    }

    func testAfterInsertReadActiveReturnsRow() throws {
        try db.insertTeamKeyIfAbsent(makeKey(id: "key-1"))
        let active = try db.readActiveTeamKey()
        XCTAssertEqual(active?.id, "key-1")
    }
}
