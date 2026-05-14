import XCTest
@testable import LeafCore

final class InviteURLV3Tests: XCTestCase {
    // Valid 22-char base64url token (UUID encoded)
    private let validToken = "AAECAwQFBgcICQoLDA0ODw"
    private let validHex = String(repeating: "ab", count: 32)
    private let validOTP = "123456"

    func testParse_validMinimal_succeeds() {
        let url = URL(string: "leaf://invite/\(validToken)?w=Acme&a=\(validHex)")!
        guard case .success(let p) = InviteURL.parse(url) else {
            XCTFail("expected success"); return
        }
        XCTAssertEqual(p.token, validToken)
        XCTAssertEqual(p.workspaceName, "Acme")
        XCTAssertEqual(p.adminPubkeyHex, validHex)
        XCTAssertNil(p.otp)
    }

    func testParse_validWithOTP_succeeds() {
        let url = URL(string: "leaf://invite/\(validToken)?w=Acme&a=\(validHex)#\(validOTP)")!
        guard case .success(let p) = InviteURL.parse(url) else { XCTFail("expected success"); return }
        XCTAssertEqual(p.otp, validOTP)
    }

    func testParse_urlEncodedWorkspaceName_decodes() {
        let url = URL(string: "leaf://invite/\(validToken)?w=Acme%20Corp&a=\(validHex)")!
        guard case .success(let p) = InviteURL.parse(url) else { XCTFail("expected success"); return }
        XCTAssertEqual(p.workspaceName, "Acme Corp")
    }

    func testParse_queryParamsInAnyOrder_succeeds() {
        let url = URL(string: "leaf://invite/\(validToken)?a=\(validHex)&w=Acme")!
        guard case .success(let p) = InviteURL.parse(url) else { XCTFail("expected reverse order"); return }
        XCTAssertEqual(p.workspaceName, "Acme")
    }

    func testParse_wrongScheme_fails() {
        let url = URL(string: "https://invite/\(validToken)?w=Acme&a=\(validHex)")!
        guard case .failure(.malformed) = InviteURL.parse(url) else { XCTFail("expected .malformed"); return }
    }

    func testParse_wrongHost_fails() {
        let url = URL(string: "leaf://join/\(validToken)?w=Acme&a=\(validHex)")!
        guard case .failure(.malformed) = InviteURL.parse(url) else { XCTFail("expected .malformed"); return }
    }

    func testParse_oldFormat32CharToken_rejected() {
        let oldToken = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef"  // 32 chars (Phase 5.5 format)
        let url = URL(string: "leaf://invite/\(oldToken)#\(validOTP)")!
        guard case .failure(.malformed) = InviteURL.parse(url) else {
            XCTFail("old format must be rejected by Track 5 strict parser"); return
        }
    }

    func testParse_tokenWrongLength_fails() {
        let short = "abc"
        let url = URL(string: "leaf://invite/\(short)?w=Acme&a=\(validHex)")!
        guard case .failure(.malformed) = InviteURL.parse(url) else { XCTFail("expected .malformed"); return }
    }

    func testParse_tokenIllegalChars_fails() {
        let bad = "AAECAwQFBgcICQoL.A0ODw"
        let url = URL(string: "leaf://invite/\(bad)?w=Acme&a=\(validHex)")!
        guard case .failure(.malformed) = InviteURL.parse(url) else { XCTFail("expected .malformed for illegal chars"); return }
    }

    func testParse_missingQueryParam_fails() {
        let url = URL(string: "leaf://invite/\(validToken)?w=Acme")!
        guard case .failure(.malformed) = InviteURL.parse(url) else { XCTFail("expected .malformed"); return }
    }

    func testParse_extraQueryParam_fails() {
        let url = URL(string: "leaf://invite/\(validToken)?w=Acme&a=\(validHex)&x=extra")!
        guard case .failure(.malformed) = InviteURL.parse(url) else { XCTFail("expected .malformed"); return }
    }

    func testParse_adminHexWrongLength_fails() {
        let short = String(repeating: "ab", count: 30)
        let url = URL(string: "leaf://invite/\(validToken)?w=Acme&a=\(short)")!
        guard case .failure(.malformed) = InviteURL.parse(url) else { XCTFail("expected .malformed"); return }
    }

    func testParse_adminHexUppercase_fails() {
        let upper = String(repeating: "AB", count: 32)
        let url = URL(string: "leaf://invite/\(validToken)?w=Acme&a=\(upper)")!
        guard case .failure(.malformed) = InviteURL.parse(url) else { XCTFail("uppercase hex must fail (strict lowercase)"); return }
    }

    func testParse_otpWrongLength_fails() {
        let url = URL(string: "leaf://invite/\(validToken)?w=Acme&a=\(validHex)#12345")!
        guard case .failure(.malformed) = InviteURL.parse(url) else { XCTFail("expected .malformed"); return }
    }

    func testParse_otpNonDigit_fails() {
        let url = URL(string: "leaf://invite/\(validToken)?w=Acme&a=\(validHex)#abcdef")!
        guard case .failure(.malformed) = InviteURL.parse(url) else { XCTFail("expected .malformed"); return }
    }

    func testParse_workspaceNameTooLong_fails() {
        let longName = String(repeating: "x", count: 65)
        let encoded = longName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let url = URL(string: "leaf://invite/\(validToken)?w=\(encoded)&a=\(validHex)")!
        guard case .failure(.malformed) = InviteURL.parse(url) else { XCTFail("expected .malformed"); return }
    }

    func testParse_emptyWorkspaceName_fails() {
        let url = URL(string: "leaf://invite/\(validToken)?w=&a=\(validHex)")!
        guard case .failure(.malformed) = InviteURL.parse(url) else { XCTFail("expected .malformed"); return }
    }
}
