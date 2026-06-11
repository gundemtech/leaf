import Foundation
import XCTest

@testable import LeafCore

final class AccountDeletionServiceTests: XCTestCase {
  private final class Spy: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [String] = []
    func record(_ s: String) {
      lock.withLock { steps.append(s) }
    }
    func snapshot() -> [String] {
      lock.withLock { steps }
    }
  }
  private struct Boom: Error {}

  func testSuccess_runsServerThenSignOutThenIdentity_inOrder() async throws {
    let spy = Spy()
    let service = AccountDeletionService(
      deleteAccount: { spy.record("server") },
      signOut: { spy.record("signOut") },
      deleteIdentity: { spy.record("identity") })
    try await service.run()
    XCTAssertEqual(spy.snapshot(), ["server", "signOut", "identity"])
  }

  func testServerFailure_skipsLocalTeardown_andRethrows() async throws {
    let spy = Spy()
    let service = AccountDeletionService(
      deleteAccount: { throw Boom() },
      signOut: { spy.record("signOut") },
      deleteIdentity: { spy.record("identity") })
    do {
      try await service.run()
      XCTFail("expected throw")
    } catch is Boom { /* expected */  }
    XCTAssertTrue(
      spy.snapshot().isEmpty, "no local teardown on server failure; got \(spy.snapshot())")
  }
}
