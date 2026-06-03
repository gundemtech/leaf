import XCTest

@testable import LeafCore

final class AsyncTimeoutTests: XCTestCase {

  func testReturnsValueWhenOperationBeatsDeadline() async throws {
    let value = try await withTimeout(.seconds(10)) { 42 }
    XCTAssertEqual(value, 42)
  }

  func testThrowsTimeoutWhenDeadlineWins() async {
    do {
      _ = try await withTimeout(.milliseconds(50)) {
        // Far longer than the deadline; gets cancelled when the deadline wins,
        // so the test does NOT actually wait this long.
        try await Task.sleep(for: .seconds(10))
        return 1
      }
      XCTFail("expected TimeoutError")
    } catch is TimeoutError {
      // expected
    } catch {
      XCTFail("expected TimeoutError, got \(error)")
    }
  }

  func testPropagatesOperationErrorWhenItFailsBeforeDeadline() async {
    struct Boom: Error {}
    do {
      _ = try await withTimeout(.seconds(10)) { () async throws -> Int in
        throw Boom()
      }
      XCTFail("expected Boom")
    } catch is TimeoutError {
      XCTFail("operation's own error must propagate, not TimeoutError")
    } catch is Boom {
      // expected
    } catch {
      XCTFail("expected Boom, got \(error)")
    }
  }
}
