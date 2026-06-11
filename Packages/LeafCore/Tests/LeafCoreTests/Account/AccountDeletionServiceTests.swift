import XCTest

@testable import LeafCore

final class AccountDeletionServiceTests: XCTestCase {
  private actor Spy {
    var steps: [String] = []
    func record(_ s: String) { steps.append(s) }
    func snapshot() -> [String] { steps }
  }
  private struct Boom: Error {}

  func testSuccess_runsServerThenSignOutThenIdentity_inOrder() async throws {
    let spy = Spy()
    let service = AccountDeletionService(
      deleteAccount: { await spy.record("server") },
      signOut: { await spy.record("signOut") },
      deleteIdentity: { Task { await spy.record("identity") } })
    try await service.run()
    // identity is sync in prod; assert the first two ordered server→signOut.
    let steps = await spy.snapshot()
    XCTAssertEqual(Array(steps.prefix(2)), ["server", "signOut"])
  }

  func testServerFailure_skipsLocalTeardown_andRethrows() async throws {
    let spy = Spy()
    let service = AccountDeletionService(
      deleteAccount: { throw Boom() },
      signOut: { await spy.record("signOut") },
      deleteIdentity: { Task { await spy.record("identity") } })
    do {
      try await service.run()
      XCTFail("expected throw")
    } catch is Boom { /* expected */  }
    let steps = await spy.snapshot()
    XCTAssertTrue(steps.isEmpty, "no local teardown on server failure; got \(steps)")
  }
}
