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
        XCTAssertEqual(perms?.int16Value, Int16(0o600), "db.key должен быть mode 0600")
    }

    func testDeleteRemovesFile() throws {
        _ = try FileKeyStore.fetchOrCreate(at: keyURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keyURL.path))

        try FileKeyStore.delete(at: keyURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyURL.path))
    }

    func testDeleteIsIdempotentWhenFileMissing() throws {
        // delete() на несуществующем файле не должен бросать (test/dev tearDown convenience).
        XCTAssertNoThrow(try FileKeyStore.delete(at: keyURL))
    }

    func testCorruptedFileShorterThan32BytesThrows() throws {
        // Defensive contract: file existed но не 32 bytes → throw, не silently regenerate
        // (это мог быть partial-write от crashed process; auto-recovery маскирует bigger problem).
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

    func testConcurrentFetchOrCreateConverges() async throws {
        // Race spec: два параллельных Task.detached вызова на свежий path должны
        // вернуть одинаковые bytes (last-writer-wins consensus через atomic+verify).
        // Не bullet-proof для arbitrary timing, но purpose'ом этого теста — поймать
        // обвал read-back logic (regression guard).
        for _ in 0..<10 {
            let url = tempDir.appendingPathComponent("race-\(UUID().uuidString).key")
            async let a = Task.detached(priority: .userInitiated) { try FileKeyStore.fetchOrCreate(at: url) }.value
            async let b = Task.detached(priority: .userInitiated) { try FileKeyStore.fetchOrCreate(at: url) }.value

            let (keyA, keyB) = try await (a, b)
            XCTAssertEqual(keyA, keyB, "Параллельные fetchOrCreate должны сойтись на одном ключе")
            XCTAssertEqual(keyA.count, 32)
        }
    }

    /// Bridge migration с legacy Keychain item. Skip on CI — требует real Keychain.
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

        // Migration path требует чтобы FileKeyStore вызвал KeychainKeyStore.fetchOnly
        // с дефолтными service/account. На реальном launchpath так и есть, но в этом
        // тесте custom service/account → миграция не triggered. Поэтому вместо проверки
        // через FileKeyStore.fetchOrCreate API проверяем contracts отдельно:
        // 1. KeychainKeyStore.fetchOnly возвращает existing key (с тем же service/account).
        // 2. FileKeyStore сам путь read→write→read консистентен.

        let fetched = try KeychainKeyStore.fetchOnly(
            accessGroup: testAccessGroup,
            service: testService,
            account: testAccount
        )
        XCTAssertEqual(fetched, legacyKey, "fetchOnly должен возвращать тот же key что fetchOrCreate")

        // Записать legacyKey в file через FileKeyStore approximation (через writeAtomic не публичен —
        // emulate через прямой Data.write + read через fetchOrCreate с file-exists branch).
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try legacyKey.write(to: keyURL)

        let viaFileStore = try FileKeyStore.fetchOrCreate(at: keyURL)
        XCTAssertEqual(viaFileStore, legacyKey, "FileKeyStore читает существующий file верно")
    }
}
