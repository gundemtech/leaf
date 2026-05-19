// Track 5 / S8 / T9 — Database.{readNotificationPrefs / isNotificationPrefEnabled
// / setNotificationPref} public wrapper coverage.
//
// The wrappers delegate to `NotificationPrefsStore` (covered by T1
// NotificationPrefsStoreTests); this file pins the writer/reader mode gate
// + the integration with `pool.write` / `pool.read` so callers like
// `NotificationPrefsReader` (T9) bind to a known surface.

import XCTest
import GRDB
@testable import LeafCore

final class DatabaseNotificationPrefsTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-db-notif-prefs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeWriter() throws -> LeafCore.Database {
        try LeafCore.Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    private func makeReader() throws -> LeafCore.Database {
        try LeafCore.Database.openForRead(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    // MARK: - readNotificationPrefs

    func testReadNotificationPrefs_DefaultsForEveryKind() throws {
        let db = try makeWriter()
        let map = try db.readNotificationPrefs()
        XCTAssertEqual(map.count, NotificationKind.allCases.count)
        XCTAssertEqual(map[.handoff], true)
        XCTAssertEqual(map[.openQuestion], false)
        XCTAssertEqual(map[.sound], true)
    }

    func testReadNotificationPrefs_AfterSet_ReflectsOverride() throws {
        let db = try makeWriter()
        try db.setNotificationPref(.task, enabled: false, updatedAtMs: 100)
        let map = try db.readNotificationPrefs()
        XCTAssertEqual(map[.task], false)
        // Sanity: another kind still at default.
        XCTAssertEqual(map[.ping], true)
    }

    // MARK: - isNotificationPrefEnabled

    func testIsNotificationPrefEnabled_DefaultsFallback() throws {
        let db = try makeWriter()
        XCTAssertTrue(try db.isNotificationPrefEnabled(.coalesce))
        XCTAssertFalse(try db.isNotificationPrefEnabled(.openQuestion))
    }

    func testIsNotificationPrefEnabled_AfterSet_ReturnsOverride() throws {
        let db = try makeWriter()
        try db.setNotificationPref(.decision, enabled: false, updatedAtMs: 100)
        XCTAssertFalse(try db.isNotificationPrefEnabled(.decision))
    }

    // MARK: - setNotificationPref — mode gate

    func testSetNotificationPref_ReaderMode_Throws() throws {
        // Touch the file with a writer first so the reader can open it.
        _ = try makeWriter()
        let reader = try makeReader()
        XCTAssertThrowsError(
            try reader.setNotificationPref(.task, enabled: false, updatedAtMs: 100)
        ) { error in
            guard case LeafError.databaseUnavailable = error else {
                XCTFail("expected databaseUnavailable; got \(error)")
                return
            }
        }
    }

    // MARK: - setNotificationPref — locked-kind enforcement (propagated from store)

    func testSetNotificationPref_LockedHandoffDisable_ThrowsStoreError() throws {
        let db = try makeWriter()
        XCTAssertThrowsError(
            try db.setNotificationPref(.handoff, enabled: false, updatedAtMs: 100)
        ) { error in
            guard case NotificationPrefsStore.Error.cannotDisableLockedKind = error else {
                XCTFail("expected cannotDisableLockedKind; got \(error)")
                return
            }
        }
    }
}
