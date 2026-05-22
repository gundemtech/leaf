import XCTest

@testable import LeafCore

final class SupabaseErrorMappingTests: XCTestCase {
  func testStatusMapping() {
    XCTAssertEqual(SupabaseError.fromStatus(400, body: nil), .badRequest)
    XCTAssertEqual(SupabaseError.fromStatus(401, body: nil), .unauthorized)
    XCTAssertEqual(SupabaseError.fromStatus(404, body: nil), .notFound)
    XCTAssertEqual(SupabaseError.fromStatus(409, body: nil), .conflict)
    XCTAssertEqual(SupabaseError.fromStatus(429, body: nil), .rateLimited)
    XCTAssertEqual(SupabaseError.fromStatus(500, body: nil), .serverError)
    XCTAssertEqual(SupabaseError.fromStatus(503, body: nil), .serverError)
    XCTAssertEqual(SupabaseError.fromStatus(418, body: nil), .unexpected(status: 418))
  }

  func testInviteResolveSpecificMapping() {
    let err = SupabaseError.fromInviteResolve(
      status: 404, body: Data(#"{"error":"not_resolvable"}"#.utf8))
    XCTAssertEqual(err, .inviteNotResolvable)
  }

  func testInviteResolve400Distinct() {
    let err = SupabaseError.fromInviteResolve(status: 400, body: nil)
    XCTAssertEqual(err, .badRequest)
  }

  func testRegisterPubkey409TOFU() {
    let err = SupabaseError.fromRegisterPubkey(status: 409, body: nil)
    XCTAssertEqual(err, .pubkeyAlreadyRegistered)
  }

  // MARK: - 410 Gone body-parsing (M027 invite-redesign Amendment 2026-05-22)

  func test410_withInviteNotFoundBody_returnsGone() {
    let body = Data(#"{"error":"invite_not_found"}"#.utf8)
    XCTAssertEqual(SupabaseError.fromStatus(410, body: body), .gone(code: "invite_not_found"))
  }

  func test410_withInviteExhaustedBody_returnsGone() {
    let body = Data(#"{"error":"invite_exhausted"}"#.utf8)
    XCTAssertEqual(SupabaseError.fromStatus(410, body: body), .gone(code: "invite_exhausted"))
  }

  func test410_withWorkspaceMismatchBody_returnsGone() {
    let body = Data(#"{"error":"workspace_mismatch"}"#.utf8)
    XCTAssertEqual(SupabaseError.fromStatus(410, body: body), .gone(code: "workspace_mismatch"))
  }

  func test410_withNilBody_fallsBackToUnexpected() {
    XCTAssertEqual(SupabaseError.fromStatus(410, body: nil), .unexpected(status: 410))
  }

  func test410_withEmptyBody_fallsBackToUnexpected() {
    XCTAssertEqual(SupabaseError.fromStatus(410, body: Data()), .unexpected(status: 410))
  }

  func test410_withInvalidJSON_fallsBackToUnexpected() {
    let body = Data("not json at all".utf8)
    XCTAssertEqual(SupabaseError.fromStatus(410, body: body), .unexpected(status: 410))
  }

  func test410_withJSONLackingErrorKey_fallsBackToUnexpected() {
    let body = Data(#"{"detail":"something"}"#.utf8)
    XCTAssertEqual(SupabaseError.fromStatus(410, body: body), .unexpected(status: 410))
  }

  func test410_withErrorAsNonString_fallsBackToUnexpected() {
    let body = Data(#"{"error":42}"#.utf8)
    XCTAssertEqual(SupabaseError.fromStatus(410, body: body), .unexpected(status: 410))
  }

  func test410_withEmptyErrorString_fallsBackToUnexpected() {
    let body = Data(#"{"error":""}"#.utf8)
    XCTAssertEqual(SupabaseError.fromStatus(410, body: body), .unexpected(status: 410))
  }

  func test410_withExtraJSONFields_stillExtractsErrorCode() {
    let body = Data(#"{"error":"invite_expired","detail":"24h TTL exceeded"}"#.utf8)
    XCTAssertEqual(SupabaseError.fromStatus(410, body: body), .gone(code: "invite_expired"))
  }
}
