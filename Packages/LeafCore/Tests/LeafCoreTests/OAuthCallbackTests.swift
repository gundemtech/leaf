import XCTest

@testable import LeafCore

final class OAuthCallbackTests: XCTestCase {
  func testProceedWithCode() {
    XCTAssertEqual(OAuthCallback.evaluate(items: [("code", "abc")]), .proceed(code: "abc"))
  }

  // GoTrue may echo its own provider-leg state on the redirect; we ignore it.
  func testProceedIgnoresAnyState() {
    XCTAssertEqual(
      OAuthCallback.evaluate(items: [("code", "abc"), ("state", "gotrue-xyz")]),
      .proceed(code: "abc"))
  }

  func testAccessDeniedIsCancelled() {
    XCTAssertEqual(OAuthCallback.evaluate(items: [("error", "access_denied")]), .cancelled)
  }

  func testOtherProviderErrorIsProviderError() {
    XCTAssertEqual(OAuthCallback.evaluate(items: [("error", "server_error")]), .providerError)
  }

  // A provider error short-circuits before the code is read.
  func testErrorTakesPrecedenceOverCode() {
    XCTAssertEqual(
      OAuthCallback.evaluate(items: [("error", "access_denied"), ("code", "abc")]), .cancelled)
  }

  func testMissingCode() {
    XCTAssertEqual(OAuthCallback.evaluate(items: [("state", "x")]), .missingCode)
  }
}
