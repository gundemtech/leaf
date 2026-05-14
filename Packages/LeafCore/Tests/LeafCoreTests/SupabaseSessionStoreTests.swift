// Phase Track-5 S4 — SupabaseSessionStore round-trip + permissions coverage.

import XCTest
@testable import LeafCore

final class SupabaseSessionStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-supabase-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testReadMissingFile_ReturnsNil() throws {
        let store = SupabaseSessionStore(at: tempDir)
        let session = try store.read()
        XCTAssertNil(session)
    }

    func testWriteThenRead_RoundTrip() throws {
        let store = SupabaseSessionStore(at: tempDir)
        let session = PersistedSession(
            refreshToken: "rt-abc",
            userID: "uid-1",
            savedAtMs: 1_700_000_000_000
        )
        try store.write(session)

        let read = try store.read()
        XCTAssertEqual(read, session)
    }

    func testWriteSetsStrictPermissions_0o600() throws {
        let store = SupabaseSessionStore(at: tempDir)
        try store.write(PersistedSession(refreshToken: "x", userID: "y", savedAtMs: 1))

        let filePath = tempDir.appendingPathComponent("supabase-session.json").path
        let attrs = try FileManager.default.attributesOfItem(atPath: filePath)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(perms, 0o600, "expected 0o600, got \(String(format: "0o%o", perms))")
    }

    func testWriteSecondTime_OverwritesFirst() throws {
        let store = SupabaseSessionStore(at: tempDir)
        try store.write(PersistedSession(refreshToken: "first", userID: "u", savedAtMs: 1))
        try store.write(PersistedSession(refreshToken: "second", userID: "u", savedAtMs: 2))

        let read = try store.read()
        XCTAssertEqual(read?.refreshToken, "second")
        XCTAssertEqual(read?.savedAtMs, 2)
    }

    func testClear_RemovesFile() throws {
        let store = SupabaseSessionStore(at: tempDir)
        try store.write(PersistedSession(refreshToken: "x", userID: "y", savedAtMs: 1))

        let filePath = tempDir.appendingPathComponent("supabase-session.json").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: filePath))

        try store.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: filePath))
    }

    func testClear_NoOpOnMissingFile() throws {
        let store = SupabaseSessionStore(at: tempDir)
        XCTAssertNoThrow(try store.clear())
    }

    func testReadCorruptedJSON_ThrowsSessionStoreFailure() throws {
        let store = SupabaseSessionStore(at: tempDir)
        let filePath = tempDir.appendingPathComponent("supabase-session.json")
        try "not-json-{".data(using: .utf8)!.write(to: filePath)

        XCTAssertThrowsError(try store.read()) { err in
            if case LeafError.supabaseSessionStoreFailure = err { return }
            XCTFail("expected supabaseSessionStoreFailure, got \(err)")
        }
    }

    func testSnakeCaseWireKeys() throws {
        let store = SupabaseSessionStore(at: tempDir)
        try store.write(PersistedSession(refreshToken: "abc", userID: "uid-1", savedAtMs: 9999))

        let filePath = tempDir.appendingPathComponent("supabase-session.json")
        let raw = try String(contentsOf: filePath, encoding: .utf8)
        XCTAssertTrue(raw.contains("\"refresh_token\""), "expected refresh_token; got \(raw)")
        XCTAssertTrue(raw.contains("\"user_id\""), "expected user_id; got \(raw)")
        XCTAssertTrue(raw.contains("\"saved_at_ms\""), "expected saved_at_ms; got \(raw)")
    }

    func testCreatesDirectoryIfMissing() throws {
        let nested = tempDir.appendingPathComponent("nested/dir", isDirectory: true)
        let store = SupabaseSessionStore(at: nested)
        XCTAssertNoThrow(
            try store.write(PersistedSession(refreshToken: "r", userID: "u", savedAtMs: 1))
        )
    }
}
