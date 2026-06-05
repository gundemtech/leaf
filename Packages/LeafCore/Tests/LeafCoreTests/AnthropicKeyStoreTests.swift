import XCTest

@testable import LeafCore

final class AnthropicKeyStoreTests: XCTestCase {
  // Unsigned unit tests use the default keychain (no access group). Skipped on
  // CI where there is no real keychain (mirrors KeychainKeyStoreTests).
  private let store = KeychainAnthropicKeyStore(
    service: "tech.gundem.leaf.anthropic.tests",
    account: "byok-test-\(UUID().uuidString)")

  override func setUp() async throws {
    try XCTSkipIf(
      ProcessInfo.processInfo.environment["CI"] == "true",
      "Keychain tests require a real Keychain — skipped on CI")
    try? store.deleteKey()
  }

  override func tearDown() async throws {
    try? store.deleteKey()
  }

  func testStoreThenLoadRoundTrips() throws {
    try store.storeKey("byok-test-key-ABC123")
    XCTAssertEqual(try store.loadKey(), "byok-test-key-ABC123")
  }

  func testLoadReturnsNilWhenAbsent() throws {
    XCTAssertNil(try store.loadKey())
  }

  func testStoreUpsertsExistingKey() throws {
    try store.storeKey("first")
    try store.storeKey("second")
    XCTAssertEqual(try store.loadKey(), "second")
  }

  func testDeleteRemovesKey() throws {
    try store.storeKey("to-delete")
    try store.deleteKey()
    XCTAssertNil(try store.loadKey())
  }
}
