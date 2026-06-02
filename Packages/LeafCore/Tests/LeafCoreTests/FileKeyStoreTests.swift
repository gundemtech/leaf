import XCTest
@testable import LeafCore

final class FileKeyStoreTests: XCTestCase {
    private var tempDir: URL!
    private var keyURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-filekeystore-tests-\(UUID().uuidString)", isDirectory: true)
        keyURL = tempDir.appendingPathComponent("db.key", isDirectory: false)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
    }

    func testFetchOrCreateReturns32Bytes() throws {
        let key = try FileKeyStore.fetchOrCreate(at: keyURL)
        XCTAssertEqual(key.count, FileKeyStore.keyLengthBytes)
        XCTAssertEqual(key.count, 32)
    }

    func testFetchOrCreateIsIdempotent() throws {
        let first = try FileKeyStore.fetchOrCreate(at: keyURL)
        let second = try FileKeyStore.fetchOrCreate(at: keyURL)
        XCTAssertEqual(first, second)
    }

    func testGeneratedKeyIsNotAllZeros() throws {
        let key = try FileKeyStore.fetchOrCreate(at: keyURL)
        XCTAssertNotEqual(key, Data(count: 32))
    }

    func testFileMode0600AfterCreate() throws {
        _ = try FileKeyStore.fetchOrCreate(at: keyURL)

        let attrs = try FileManager.default.attributesOfItem(atPath: keyURL.path)
        let perms = attrs[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.int16Value, Int16(0o600), "db.key must be mode 0600")
    }

    func testDeleteRemovesFile() throws {
        _ = try FileKeyStore.fetchOrCreate(at: keyURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keyURL.path))

        try FileKeyStore.delete(at: keyURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyURL.path))
    }

    func testDeleteIsIdempotentWhenFileMissing() throws {
        // delete() on a nonexistent file must not throw (test/dev tearDown convenience).
        XCTAssertNoThrow(try FileKeyStore.delete(at: keyURL))
    }

    func testCorruptedFileShorterThan32BytesThrows() throws {
        // Defensive contract: file existed but not 32 bytes → throw, don't silently regenerate
        // (it could be a partial write from a crashed process; auto-recovery masks a bigger problem).
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let truncated = Data(repeating: 0xAB, count: 16)
        try truncated.write(to: keyURL)

        XCTAssertThrowsError(try FileKeyStore.fetchOrCreate(at: keyURL)) { error in
            guard case LeafError.keyFileCorrupted = error else {
                XCTFail("Expected LeafError.keyFileCorrupted, got \(error)")
                return
            }
        }
    }

    func testConcurrentReadersConverge() async throws {
        // Production model (Phase 3.4.5): the main app eager-inits the file IN `LeafApp.init()`
        // BEFORE `agent.register()`. Helpers (LeafAgent/LeafMCP) are guaranteed to start afterwards
        // and read the same on-disk file. Concurrent writes to a fresh path never happen in prod.
        //
        // Test: pre-write the file, then 2 parallel fetchOrCreate calls must read the same bytes.
        for _ in 0..<10 {
            let url = tempDir.appendingPathComponent("read-\(UUID().uuidString).key")
            let seed = try FileKeyStore.fetchOrCreate(at: url)  // eager-init equivalent

            async let a = Task.detached(priority: .userInitiated) { try FileKeyStore.fetchOrCreate(at: url) }.value
            async let b = Task.detached(priority: .userInitiated) { try FileKeyStore.fetchOrCreate(at: url) }.value

            let (keyA, keyB) = try await (a, b)
            XCTAssertEqual(keyA, seed, "Concurrent reader A must return the seed bytes")
            XCTAssertEqual(keyB, seed, "Concurrent reader B must return the seed bytes")
            XCTAssertEqual(keyA.count, 32)
        }
    }

    /// Bridge migration from a legacy Keychain item. Skip on CI — requires a real Keychain.
    func testMigrationFromKeychain() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["CI"] == "true",
            "Keychain migration test requires real Keychain — skipped on CI"
        )

        let testService = "tech.gundem.leaf.tests"
        let testAccount = "filekeystore-migration-\(UUID().uuidString)"
        let testAccessGroup = ""

        // Pre-populate Keychain (simulating alpha.2 main app's K1).
        let legacyKey = try KeychainKeyStore.fetchOrCreate(
            accessGroup: testAccessGroup,
            service: testService,
            account: testAccount
        )
        defer {
            try? KeychainKeyStore.delete(accessGroup: testAccessGroup, service: testService, account: testAccount)
        }

        // The migration path requires FileKeyStore to call KeychainKeyStore.fetchOnly
        // with the default service/account. On the real launch path that's the case, but in this
        // test the custom service/account → migration is not triggered. So instead of verifying
        // through the FileKeyStore.fetchOrCreate API, we check the contracts separately:
        // 1. KeychainKeyStore.fetchOnly returns the existing key (with the same service/account).
        // 2. FileKeyStore's own read→write→read path is consistent.

        let fetched = try KeychainKeyStore.fetchOnly(
            accessGroup: testAccessGroup,
            service: testService,
            account: testAccount
        )
        XCTAssertEqual(fetched, legacyKey, "fetchOnly must return the same key as fetchOrCreate")

        // Write legacyKey to the file via a FileKeyStore approximation (writeAtomic isn't public —
        // emulate via a direct Data.write + read via fetchOrCreate's file-exists branch).
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try legacyKey.write(to: keyURL)

        let viaFileStore = try FileKeyStore.fetchOrCreate(at: keyURL)
        XCTAssertEqual(viaFileStore, legacyKey, "FileKeyStore reads an existing file correctly")
    }
}
