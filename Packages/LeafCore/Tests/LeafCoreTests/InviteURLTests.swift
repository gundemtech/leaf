// Phase 5.5.A — InviteURL parser/composer (`leaf://invite/<token>#<otp>`).

import XCTest

@testable import LeafCore

final class InviteURLTests: XCTestCase {
    // 32-char base64url token + 6-digit OTP — both per Phase 5.2.D.
    private let validToken = "abcdefghijklmnopqrstuvwxyz012345"
    private let validOTP = "123456"

    func testComposeParse_RoundTrip() throws {
        let url = InviteURL.compose(token: validToken, otp: validOTP)
        let parsed = try InviteURL.parse(url).get()
        XCTAssertEqual(parsed.token, validToken)
        XCTAssertEqual(parsed.otp, validOTP)
    }

    func testParse_RejectsWrongScheme() {
        let url = URL(string: "https://invite/\(validToken)#\(validOTP)")!
        switch InviteURL.parse(url) {
        case .success: XCTFail("expected malformed")
        case .failure(let err): XCTAssertEqual(err, .malformed)
        }
    }

    func testParse_RejectsWrongHost() {
        let url = URL(string: "leaf://join/\(validToken)#\(validOTP)")!
        switch InviteURL.parse(url) {
        case .success: XCTFail("expected malformed")
        case .failure(let err): XCTAssertEqual(err, .malformed)
        }
    }

    func testParse_RejectsMissingFragment() {
        let url = URL(string: "leaf://invite/\(validToken)")!
        switch InviteURL.parse(url) {
        case .success: XCTFail("expected malformed")
        case .failure(let err): XCTAssertEqual(err, .malformed)
        }
    }

    func testParse_RejectsMalformedToken() {
        // Non-base64url chars.
        let bad1 = URL(
            string:
                "leaf://invite/\("token with spaces and !!!".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)#\(validOTP)"
        )!
        switch InviteURL.parse(bad1) {
        case .success: XCTFail("expected malformed")
        case .failure(let err): XCTAssertEqual(err, .malformed)
        }
        // 31 chars (one short).
        let short = String(validToken.dropLast())
        let bad2 = URL(string: "leaf://invite/\(short)#\(validOTP)")!
        switch InviteURL.parse(bad2) {
        case .success: XCTFail("expected malformed")
        case .failure(let err): XCTAssertEqual(err, .malformed)
        }
    }

    func testParse_RejectsMalformedOTP() {
        // 5 digits.
        let bad1 = URL(string: "leaf://invite/\(validToken)#12345")!
        switch InviteURL.parse(bad1) {
        case .success: XCTFail("expected malformed (5 digits)")
        case .failure(let err): XCTAssertEqual(err, .malformed)
        }
        // Letters in OTP.
        let bad2 = URL(string: "leaf://invite/\(validToken)#abcdef")!
        switch InviteURL.parse(bad2) {
        case .success: XCTFail("expected malformed (letters)")
        case .failure(let err): XCTAssertEqual(err, .malformed)
        }
        // Empty fragment (different from "missing fragment" — empty `#` after).
        let bad3 = URL(string: "leaf://invite/\(validToken)#")!
        switch InviteURL.parse(bad3) {
        case .success: XCTFail("expected malformed (empty)")
        case .failure(let err): XCTAssertEqual(err, .malformed)
        }
    }
}
