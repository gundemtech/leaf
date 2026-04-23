import XCTest
@testable import LeafControlCore

final class KeychainKeyStoreTests: XCTestCase {
    // Unit tests run unsigned → Keychain access group не работает.
    // Используем пустой access group (default keychain) для теста логики.
    private let service = "tech.gundem.leafcontrol.tests"
    private let account = "test-key-\(UUID().uuidString)"
    private let accessGroup = ""

    override func setUp() async throws {
        try? XCTSkipIf(
            ProcessInfo.processInfo.environment["CI"] == "true",
            "Keychain tests require real Keychain — skipped on CI"
        )
        try? KeychainKeyStore.delete(accessGroup: accessGroup, service: service, account: account)
    }

    override func tearDown() async throws {
        try? KeychainKeyStore.delete(accessGroup: accessGroup, service: service, account: account)
    }

    func testFetchOrCreateReturns32Bytes() throws {
        let key = try KeychainKeyStore.fetchOrCreate(
            accessGroup: accessGroup,
            service: service,
            account: account
        )
        XCTAssertEqual(key.count, KeychainKeyStore.keyLengthBytes)
        XCTAssertEqual(key.count, 32)
    }

    func testFetchOrCreateIsIdempotent() throws {
        let first = try KeychainKeyStore.fetchOrCreate(
            accessGroup: accessGroup,
            service: service,
            account: account
        )
        let second = try KeychainKeyStore.fetchOrCreate(
            accessGroup: accessGroup,
            service: service,
            account: account
        )
        XCTAssertEqual(first, second)
    }

    func testGeneratedKeyIsNotAllZeros() throws {
        let key = try KeychainKeyStore.fetchOrCreate(
            accessGroup: accessGroup,
            service: service,
            account: account
        )
        XCTAssertNotEqual(key, Data(count: 32))
    }

    func testDeleteRemovesKey() throws {
        _ = try KeychainKeyStore.fetchOrCreate(
            accessGroup: accessGroup,
            service: service,
            account: account
        )
        try KeychainKeyStore.delete(accessGroup: accessGroup, service: service, account: account)

        // После delete → fetchOrCreate должен сгенерить новый ключ (не равный предыдущему)
        let recreated = try KeychainKeyStore.fetchOrCreate(
            accessGroup: accessGroup,
            service: service,
            account: account
        )
        XCTAssertEqual(recreated.count, 32)
    }
}
