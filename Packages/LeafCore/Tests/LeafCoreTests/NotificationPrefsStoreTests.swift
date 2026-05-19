// Track 5 / S8 / T1 — NotificationPrefsStore CRUD invariants.
//
// Mirrors `ShareRulesStoreTests` shape (per-row normalized + defaults map fallback).
// Additional coverage: `.handoff` locked-disable reject, redundant locked-enable
// no-op success, UPSERT semantics across re-writes.

import XCTest
import GRDB
@testable import LeafCore

final class NotificationPrefsStoreTests: XCTestCase {
    private var tempDir: URL!
    private var db: LeafCore.Database!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-notif-prefs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        db = try LeafCore.Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    override func tearDown() async throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Defaults fallback

    func testReadEffective_NoRows_ReturnsDefaultsForAllKinds() throws {
        let map = try db.writeSQL { rawDB in
            try NotificationPrefsStore.readEffective(in: rawDB)
        }
        XCTAssertEqual(map.count, NotificationKind.allCases.count, "should cover every kind")
        // Defaults per contract §10.2
        XCTAssertEqual(map[.handoff], true)
        XCTAssertEqual(map[.task], true)
        XCTAssertEqual(map[.ping], true)
        XCTAssertEqual(map[.decision], true)
        XCTAssertEqual(map[.blocker], true)
        XCTAssertEqual(map[.openQuestion], false)
        XCTAssertEqual(map[.whereStopped], false)
        XCTAssertEqual(map[.rawActivity], false)
        XCTAssertEqual(map[.respectFocus], true)
        XCTAssertEqual(map[.coalesce], true)
        XCTAssertEqual(map[.sound], true)
    }

    // MARK: - UPSERT semantics

    func testSetEnabled_PersistsAcrossReads() throws {
        try db.writeSQL { rawDB in
            try NotificationPrefsStore.setEnabled(.task, enabled: false, updatedAtMs: 100, in: rawDB)
        }
        let map = try db.writeSQL { rawDB in
            try NotificationPrefsStore.readEffective(in: rawDB)
        }
        XCTAssertEqual(map[.task], false)
        XCTAssertEqual(map[.handoff], true)  // other defaults preserved
        XCTAssertEqual(map[.ping], true)
    }

    func testSetEnabled_Upsert_OverwritesPriorValue() throws {
        try db.writeSQL { rawDB in
            try NotificationPrefsStore.setEnabled(.coalesce, enabled: false, updatedAtMs: 100, in: rawDB)
            try NotificationPrefsStore.setEnabled(.coalesce, enabled: true, updatedAtMs: 200, in: rawDB)
        }
        let map = try db.writeSQL { rawDB in
            try NotificationPrefsStore.readEffective(in: rawDB)
        }
        XCTAssertEqual(map[.coalesce], true)
    }

    func testSetEnabled_Upsert_UpdatesTimestamp() throws {
        try db.writeSQL { rawDB in
            try NotificationPrefsStore.setEnabled(.sound, enabled: false, updatedAtMs: 100, in: rawDB)
            try NotificationPrefsStore.setEnabled(.sound, enabled: true, updatedAtMs: 200, in: rawDB)
        }
        let row = try db.writeSQL { rawDB in
            try NotificationPrefsStore.read(.sound, in: rawDB)
        }
        XCTAssertEqual(row?.updatedAtMs, 200)
        XCTAssertEqual(row?.enabled, true)
    }

    // MARK: - Locked-kind reject

    func testSetEnabled_LockedHandoff_DisableRejected() throws {
        XCTAssertThrowsError(
            try db.writeSQL { rawDB in
                try NotificationPrefsStore.setEnabled(.handoff, enabled: false, updatedAtMs: 100, in: rawDB)
            }
        ) { error in
            guard case NotificationPrefsStore.Error.cannotDisableLockedKind = error else {
                XCTFail("expected cannotDisableLockedKind; got \(error)")
                return
            }
        }
        // No row should have been written.
        let row = try db.writeSQL { rawDB in
            try NotificationPrefsStore.read(.handoff, in: rawDB)
        }
        XCTAssertNil(row)
    }

    func testSetEnabled_LockedHandoff_EnableTrue_NoOpSuccess() throws {
        // Enabling a locked-ON kind is redundant but must not throw — it should
        // succeed silently (no-op for caller, persist row for storage invariant).
        try db.writeSQL { rawDB in
            try NotificationPrefsStore.setEnabled(.handoff, enabled: true, updatedAtMs: 100, in: rawDB)
        }
        let map = try db.writeSQL { rawDB in
            try NotificationPrefsStore.readEffective(in: rawDB)
        }
        XCTAssertEqual(map[.handoff], true)
    }

    // MARK: - isEnabled convenience

    func testIsEnabled_AfterToggle_ReturnsLatest() throws {
        try db.writeSQL { rawDB in
            try NotificationPrefsStore.setEnabled(.ping, enabled: false, updatedAtMs: 100, in: rawDB)
        }
        let enabled = try db.writeSQL { rawDB in
            try NotificationPrefsStore.isEnabled(.ping, in: rawDB)
        }
        XCTAssertFalse(enabled)
    }

    func testIsEnabled_AbsentRow_FallsBackToDefault() throws {
        // openQuestion default OFF, no row written.
        let enabled = try db.writeSQL { rawDB in
            try NotificationPrefsStore.isEnabled(.openQuestion, in: rawDB)
        }
        XCTAssertFalse(enabled)
    }

    // MARK: - read

    func testRead_ReturnsPersistedRow() throws {
        try db.writeSQL { rawDB in
            try NotificationPrefsStore.setEnabled(.blocker, enabled: false, updatedAtMs: 500, in: rawDB)
        }
        let row = try db.writeSQL { rawDB in
            try NotificationPrefsStore.read(.blocker, in: rawDB)
        }
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.kind, .blocker)
        XCTAssertEqual(row?.enabled, false)
        XCTAssertEqual(row?.updatedAtMs, 500)
    }

    func testRead_NilWhenAbsent() throws {
        let row = try db.writeSQL { rawDB in
            try NotificationPrefsStore.read(.rawActivity, in: rawDB)
        }
        XCTAssertNil(row)
    }

    // MARK: - allCases coverage in defaults map

    func testReadEffective_CoversEveryNotificationKind() throws {
        let map = try db.writeSQL { rawDB in
            try NotificationPrefsStore.readEffective(in: rawDB)
        }
        for kind in NotificationKind.allCases {
            XCTAssertNotNil(map[kind], "kind \(kind) missing from effective map")
        }
    }
}
