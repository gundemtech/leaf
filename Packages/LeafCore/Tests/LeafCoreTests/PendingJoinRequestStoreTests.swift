import XCTest

@testable import LeafCore

/// Tests for the UserDefaults-backed store that persists the invitee's OWN
/// pending join-request IDs so an approved invite can be materialised after
/// the waiting card is dismissed / the app relaunches (the "stranded approval"
/// gap). Each test uses an isolated UserDefaults suite.
final class PendingJoinRequestStoreTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!

  override func setUp() async throws {
    suiteName = "pending-jr-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
  }

  override func tearDown() async throws {
    defaults.removePersistentDomain(forName: suiteName)
  }

  func testEmptyByDefault() {
    let store = PendingJoinRequestStore(userDefaults: defaults)
    XCTAssertEqual(store.all(), [])
  }

  func testAddPersistsAcrossInstances() {
    PendingJoinRequestStore(userDefaults: defaults).add("req-1")
    // Fresh instance reads the same backing store.
    let reborn = PendingJoinRequestStore(userDefaults: defaults)
    XCTAssertEqual(reborn.all(), ["req-1"])
  }

  func testAddIsDeduplicated() {
    let store = PendingJoinRequestStore(userDefaults: defaults)
    store.add("req-1")
    store.add("req-1")
    XCTAssertEqual(store.all(), ["req-1"], "adding the same id twice keeps a single entry")
  }

  func testAddPreservesInsertionOrderAcrossDistinctIDs() {
    let store = PendingJoinRequestStore(userDefaults: defaults)
    store.add("req-1")
    store.add("req-2")
    XCTAssertEqual(store.all(), ["req-1", "req-2"])
  }

  func testRemove() {
    let store = PendingJoinRequestStore(userDefaults: defaults)
    store.add("req-1")
    store.add("req-2")
    store.remove("req-1")
    XCTAssertEqual(store.all(), ["req-2"])
  }

  func testRemoveMissingIsNoOp() {
    let store = PendingJoinRequestStore(userDefaults: defaults)
    store.add("req-1")
    store.remove("does-not-exist")
    XCTAssertEqual(store.all(), ["req-1"])
  }
}
