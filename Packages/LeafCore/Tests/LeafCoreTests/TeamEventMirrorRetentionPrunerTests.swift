// Phase Track-5 S5 — TeamEventMirrorRetentionPruner invariants.

import XCTest
@testable import LeafCore

final class TeamEventMirrorRetentionPrunerTests: XCTestCase {
    private var tempDir: URL!
    private var db: LeafCore.Database!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-pruner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        db = try LeafCore.Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    override func tearDown() async throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func insertRow(eventID: String, serverCreatedAtMs: Int64) throws {
        let row = TeamEventMirrorRow(
            eventID: eventID,
            workspaceID: "wid",
            senderPubkeyHex: "shex",
            source: .gitCommits,
            kind: "gh_commit_pushed",
            plaintextPayloadJSON: "{}",
            serverCreatedAtMs: serverCreatedAtMs,
            eventTsMs: serverCreatedAtMs - 1,
            receivedAtMs: serverCreatedAtMs + 1
        )
        try db.writeSQL { rawDB in try TeamEventMirrorStore.upsert(row, in: rawDB) }
    }

    func testPrune_DefaultRetention90Days() async throws {
        let nowMs: Int64 = 1_700_000_000_000
        let day: Int64 = 86_400_000
        try insertRow(eventID: "old", serverCreatedAtMs: nowMs - 95 * day)
        try insertRow(eventID: "edge", serverCreatedAtMs: nowMs - 90 * day - 1)
        try insertRow(eventID: "recent", serverCreatedAtMs: nowMs - 30 * day)
        try insertRow(eventID: "now", serverCreatedAtMs: nowMs)

        let pruner = TeamEventMirrorRetentionPruner(
            database: db,
            now: { Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000.0) }
        )
        let removed = try await pruner.prune()
        XCTAssertEqual(removed, 2)

        let remaining = try db.readSQL { rawDB in
            try TeamEventMirrorStore.readRecent(workspaceID: "wid", in: rawDB)
        }
        XCTAssertEqual(Set(remaining.map { $0.eventID }), ["recent", "now"])
    }

    func testPrune_CustomRetentionDays() async throws {
        let nowMs: Int64 = 1_700_000_000_000
        let day: Int64 = 86_400_000
        try insertRow(eventID: "8d", serverCreatedAtMs: nowMs - 8 * day)
        try insertRow(eventID: "2d", serverCreatedAtMs: nowMs - 2 * day)

        let pruner = TeamEventMirrorRetentionPruner(
            database: db,
            retentionDays: 7,
            now: { Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000.0) }
        )
        let removed = try await pruner.prune()
        XCTAssertEqual(removed, 1)
    }

    func testPrune_NoopWhenEmpty() async throws {
        let pruner = TeamEventMirrorRetentionPruner(database: db)
        let removed = try await pruner.prune()
        XCTAssertEqual(removed, 0)
    }
}
