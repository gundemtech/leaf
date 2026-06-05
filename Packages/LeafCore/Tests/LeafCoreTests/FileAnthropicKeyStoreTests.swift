import XCTest

@testable import LeafCore

final class FileAnthropicKeyStoreTests: XCTestCase {
  private var tempRoot: URL!
  private var store: FileAnthropicKeyStore!

  override func setUpWithError() throws {
    tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("leaf-byok-test-\(UUID().uuidString)", isDirectory: true)
    store = FileAnthropicKeyStore(at: tempRoot)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: tempRoot)
  }

  func testLoadMissingReturnsNil() throws {
    // Absent file → nil (maps to .missingAPIKey at the summarizer), never a throw.
    XCTAssertNil(try store.loadKey())
  }

  func testRoundTrip() throws {
    try store.storeKey("sk-ant-TESTKEY")
    XCTAssertEqual(try store.loadKey(), "sk-ant-TESTKEY")
  }

  func testUpsertOverwrites() throws {
    try store.storeKey("first")
    try store.storeKey("second")
    XCTAssertEqual(try store.loadKey(), "second")
  }

  func testDelete() throws {
    try store.storeKey("x")
    try store.deleteKey()
    XCTAssertNil(try store.loadKey())
  }

  func testDeleteMissingIsNoOp() throws {
    XCTAssertNoThrow(try store.deleteKey())
  }

  func testTrimsWhitespace() throws {
    try store.storeKey("  sk-ant-trimmed\n")
    XCTAssertEqual(try store.loadKey(), "sk-ant-trimmed")
  }

  func testEmptyKeyReadsAsNil() throws {
    try store.storeKey("   ")  // whitespace-only → trims to empty → nil
    XCTAssertNil(try store.loadKey())
  }

  func testFilePermissionsAre0600() throws {
    try store.storeKey("x")
    let path = tempRoot.appendingPathComponent(FileAnthropicKeyStore.filename).path
    let perms = (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?
      .int16Value
    XCTAssertEqual(perms, 0o600)
  }
}
