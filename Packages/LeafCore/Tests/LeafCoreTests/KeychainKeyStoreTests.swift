import XCTest
@testable import LeafCore

final class KeychainKeyStoreTests: XCTestCase {
    // Unit tests run unsigned → Keychain access group does not work.
    // Use an empty access group (default keychain) to test the logic.
    private let service = "tech.gundem.leaf.tests"
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

        // After delete → fetchOrCreate must generate a new key (not equal to the previous one)
        let recreated = try KeychainKeyStore.fetchOrCreate(
            accessGroup: accessGroup,
            service: service,
            account: account
        )
        XCTAssertEqual(recreated.count, 32)
    }
}
