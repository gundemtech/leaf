import XCTest
@testable import LeafCore

final class TeammatePresenceReaderTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-presence-reader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
        TeammatePresenceReaderFactory.resetForTests()
    }

    override func tearDown() async throws {
        TeammatePresenceReaderFactory.resetForTests()
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testStubReturnsEmpty() throws {
        let reader = StubTeammatePresenceReader()
        let snapshots = try reader.recentTeammateSnapshots(maxAge: 600, now: Date())
        XCTAssertEqual(snapshots, [])
    }

    func testFactoryReturnsStubWhenNoProviderRegistered() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults,
                                           encryption: .deterministicTest)
        let reader = TeammatePresenceReaderFactory.make(database: db)
        let snapshots = try reader.recentTeammateSnapshots(maxAge: 600, now: Date())
        XCTAssertEqual(snapshots, [])
    }

    func testFactoryReturnsRegisteredProvider() throws {
        let sentinel = TeammateSnapshot(memberID: "m1", displayName: "Sasha",
                                        linearID: nil, branch: nil, repo: nil,
                                        currentApp: nil, lastActivityAtMs: 0)
        TeammatePresenceReaderFactory.register { _ in
            FixedReader(snapshots: [sentinel])
        }
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults,
                                           encryption: .deterministicTest)
        let reader = TeammatePresenceReaderFactory.make(database: db)
        let snapshots = try reader.recentTeammateSnapshots(maxAge: 600, now: Date())
        XCTAssertEqual(snapshots, [sentinel])
    }
}

private struct FixedReader: TeammatePresenceReader {
    let snapshots: [TeammateSnapshot]
    func recentTeammateSnapshots(maxAge: TimeInterval, now: Date) throws -> [TeammateSnapshot] {
        snapshots
    }
}
