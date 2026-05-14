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
        let err = SupabaseError.fromInviteResolve(status: 404, body: Data(#"{"error":"not_resolvable"}"#.utf8))
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
}
