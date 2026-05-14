import XCTest
@testable import LeafCore

final class InviteURLV3ComposeTests: XCTestCase {
    private let validToken = "AAECAwQFBgcICQoLDA0ODw"
    private let validHex = String(repeating: "ab", count: 32)

    func testCompose_noOTP_emitsExpectedURL() {
        let composed = InviteURL.compose(
            token: validToken,
            workspaceName: "Acme",
            adminPubkeyHex: validHex,
            otp: nil
        )
        XCTAssertEqual(composed.url.absoluteString,
                       "leaf://invite/\(validToken)?w=Acme&a=\(validHex)")
        XCTAssertNil(composed.otp)
    }

    func testCompose_withOTP_emitsFragment() {
        let composed = InviteURL.compose(
            token: validToken,
            workspaceName: "Acme",
            adminPubkeyHex: validHex,
            otp: "123456"
        )
        XCTAssertEqual(composed.url.absoluteString,
                       "leaf://invite/\(validToken)?w=Acme&a=\(validHex)#123456")
    }

    func testCompose_workspaceNameWithSpaces_urlEncodes() {
        let composed = InviteURL.compose(
            token: validToken,
            workspaceName: "Acme Corp",
            adminPubkeyHex: validHex,
            otp: nil
        )
        XCTAssertEqual(composed.url.absoluteString,
                       "leaf://invite/\(validToken)?w=Acme%20Corp&a=\(validHex)")
    }

    func testRoundTrip_compose_then_parse() {
        let composed = InviteURL.compose(
            token: validToken,
            workspaceName: "Acme",
            adminPubkeyHex: validHex,
            otp: "987654"
        )
        guard case .success(let parsed) = InviteURL.parse(composed.url) else {
            XCTFail("round-trip parse failed"); return
        }
        XCTAssertEqual(parsed.token, validToken)
        XCTAssertEqual(parsed.workspaceName, "Acme")
        XCTAssertEqual(parsed.adminPubkeyHex, validHex)
        XCTAssertEqual(parsed.otp, "987654")
    }

    func testRoundTrip_unicodeWorkspaceName() {
        let composed = InviteURL.compose(
            token: validToken,
            workspaceName: "Команда",
            adminPubkeyHex: validHex,
            otp: nil
        )
        guard case .success(let parsed) = InviteURL.parse(composed.url) else {
            XCTFail("unicode round-trip parse failed"); return
        }
        XCTAssertEqual(parsed.workspaceName, "Команда")
    }
}
