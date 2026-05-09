import XCTest
@testable import LeafCore

final class DetectorMoatPublicSubstrateTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeafDetectorMoatTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeDatabase() throws -> Database {
        try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    func testPublicSubstrate_DecisionReturnsNil() {
        XCTAssertNil(DetectorMoat.publicSubstrate.decision
            .detect(body: "решено: уходим на сервер", kind: .slackMsg, eventTsMs: 0))
    }

    func testPublicSubstrate_OpenQuestionReturnsNil() {
        XCTAssertNil(DetectorMoat.publicSubstrate.openQuestion
            .detect(body: "should we use X or Y?", kind: .slackMsg))
    }

    func testPublicSubstrate_BlockerPatternReturnsNil() {
        XCTAssertNil(DetectorMoat.publicSubstrate.blockerPattern
            .detect(body: "I'm blocked on the API key", kind: .slackMsg))
    }

    func testPublicSubstrate_LinearStuckReturnsEmpty() throws {
        let db = try makeDatabase()
        let hits = try db.readSQL { rawDB in
            try DetectorMoat.publicSubstrate.linearStuck.currentlyStuck(
                in: rawDB, nowMs: 1_000_000_000_000)
        }
        XCTAssertTrue(hits.isEmpty)
        XCTAssertEqual(DetectorMoat.publicSubstrate.linearStuck.stuckDays, .max)
    }

    func testPublicSubstrate_WhereStoppedReturnsNil() throws {
        let db = try makeDatabase()
        let out = try db.readSQL { rawDB in
            try DetectorMoat.publicSubstrate.whereStopped.derive(
                in: rawDB, sinceMs: 0, untilMs: 1_000)
        }
        XCTAssertNil(out)
        XCTAssertEqual(DetectorMoat.publicSubstrate.whereStopped.idleSeconds, .max)
    }

    func testPublicSubstrate_ExactMatchAbsence() {
        let m = DetectorMoat.publicSubstrate.absence
        let ids = [
            SlackIdentifier(userID: "alice", displayName: "Alice", realName: nil),
            SlackIdentifier(userID: "demoffsrmain", displayName: nil, realName: nil)
        ]
        XCTAssertEqual(m.match(githubLogin: "demoffsrmain",
                               slackIdentifiers: ids)?.userID, "demoffsrmain")
        XCTAssertNil(m.match(githubLogin: "ddemidov", slackIdentifiers: ids))
    }
}
