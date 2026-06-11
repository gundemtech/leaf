import XCTest

@testable import LeafCore

final class SupabaseErrorTransientTests: XCTestCase {
  func testTransientFailuresGraceTheGate() {
    XCTAssertTrue(SupabaseError.transport(reason: "offline").isTransientNetworkFailure)
    XCTAssertTrue(SupabaseError.serverError.isTransientNetworkFailure)
    XCTAssertTrue(SupabaseError.rateLimited.isTransientNetworkFailure)
  }

  func testCredentialRejectionsForceLogin() {
    XCTAssertFalse(SupabaseError.unauthorized.isTransientNetworkFailure)
    XCTAssertFalse(SupabaseError.badRequest.isTransientNetworkFailure)
    XCTAssertFalse(SupabaseError.forbidden.isTransientNetworkFailure)
    XCTAssertFalse(SupabaseError.identityClaimMissing.isTransientNetworkFailure)
  }
}
