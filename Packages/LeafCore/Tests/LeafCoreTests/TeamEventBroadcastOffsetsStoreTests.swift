// Phase Track-5 S5 — TeamEventBroadcastOffsetsStore CRUD invariants.

import XCTest
import GRDB
@testable import LeafCore

final class TeamEventBroadcastOffsetsStoreTests: XCTestCase {
    private var tempDir: URL!
    private var db: LeafCore.Database!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-broadcast-offsets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        db = try LeafCore.Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    override func tearDown() async throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testReadOrDefault_ReturnsZeroedRowWhenAbsent() throws {
        let row = try db.readSQL { rawDB in
            try TeamEventBroadcastOffsetsStore.readOrDefault(workspaceID: "wid", in: rawDB)
        }
        XCTAssertEqual(row.workspaceID, "wid")
        XCTAssertEqual(row.cursorEventID, 0)
        XCTAssertNil(row.lastAttemptAtMs)
        XCTAssertNil(row.lastSuccessAtMs)
        XCTAssertEqual(row.consecutiveFailures, 0)
    }

    func testAdvanceCursor_UpsertsAndOverwrites() throws {
        try db.writeSQL { rawDB in
            try TeamEventBroadcastOffsetsStore.advanceCursor(workspaceID: "wid", toEventID: 42, in: rawDB)
        }
        let row1 = try db.readSQL { rawDB in
            try TeamEventBroadcastOffsetsStore.readOrDefault(workspaceID: "wid", in: rawDB)
        }
        XCTAssertEqual(row1.cursorEventID, 42)

        try db.writeSQL { rawDB in
            try TeamEventBroadcastOffsetsStore.advanceCursor(workspaceID: "wid", toEventID: 99, in: rawDB)
        }
        let row2 = try db.readSQL { rawDB in
            try TeamEventBroadcastOffsetsStore.readOrDefault(workspaceID: "wid", in: rawDB)
        }
        XCTAssertEqual(row2.cursorEventID, 99)
    }

    func testRecordSuccess_ResetsFailuresAndStampsTimestamps() throws {
        try db.writeSQL { rawDB in
            try TeamEventBroadcastOffsetsStore.recordFailure(workspaceID: "wid", nowMs: 100, in: rawDB)
            try TeamEventBroadcastOffsetsStore.recordFailure(workspaceID: "wid", nowMs: 200, in: rawDB)
            try TeamEventBroadcastOffsetsStore.recordFailure(workspaceID: "wid", nowMs: 300, in: rawDB)
        }
        let beforeSuccess = try db.readSQL { rawDB in
            try TeamEventBroadcastOffsetsStore.readOrDefault(workspaceID: "wid", in: rawDB)
        }
        XCTAssertEqual(beforeSuccess.consecutiveFailures, 3)
        XCTAssertEqual(beforeSuccess.lastAttemptAtMs, 300)
        XCTAssertNil(beforeSuccess.lastSuccessAtMs)

        try db.writeSQL { rawDB in
            try TeamEventBroadcastOffsetsStore.recordSuccess(workspaceID: "wid", nowMs: 1_000, in: rawDB)
        }
        let afterSuccess = try db.readSQL { rawDB in
            try TeamEventBroadcastOffsetsStore.readOrDefault(workspaceID: "wid", in: rawDB)
        }
        XCTAssertEqual(afterSuccess.consecutiveFailures, 0)
        XCTAssertEqual(afterSuccess.lastAttemptAtMs, 1_000)
        XCTAssertEqual(afterSuccess.lastSuccessAtMs, 1_000)
    }

    func testRecordFailure_IncrementsCounter() throws {
        try db.writeSQL { rawDB in
            try TeamEventBroadcastOffsetsStore.recordFailure(workspaceID: "wid", nowMs: 100, in: rawDB)
            try TeamEventBroadcastOffsetsStore.recordFailure(workspaceID: "wid", nowMs: 200, in: rawDB)
        }
        let row = try db.readSQL { rawDB in
            try TeamEventBroadcastOffsetsStore.readOrDefault(workspaceID: "wid", in: rawDB)
        }
        XCTAssertEqual(row.consecutiveFailures, 2)
        XCTAssertEqual(row.lastAttemptAtMs, 200)
    }

    func testWorkspaceIsolation_PerWorkspaceCursor() throws {
        try db.writeSQL { rawDB in
            try TeamEventBroadcastOffsetsStore.advanceCursor(workspaceID: "wid-a", toEventID: 10, in: rawDB)
            try TeamEventBroadcastOffsetsStore.advanceCursor(workspaceID: "wid-b", toEventID: 20, in: rawDB)
        }
        let a = try db.readSQL { rawDB in
            try TeamEventBroadcastOffsetsStore.readOrDefault(workspaceID: "wid-a", in: rawDB)
        }
        let b = try db.readSQL { rawDB in
            try TeamEventBroadcastOffsetsStore.readOrDefault(workspaceID: "wid-b", in: rawDB)
        }
        XCTAssertEqual(a.cursorEventID, 10)
        XCTAssertEqual(b.cursorEventID, 20)
    }
}
