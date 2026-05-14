import XCTest
import Foundation
@testable import LeafCore

final class ClipboardMatcherTests: XCTestCase {
    func testMatch_PrefersInviteURLOverJoinCode() {
        // Track 5 §12 native format: leaf://invite/<22-char-token>?w=<name>&a=<64-hex>[#otp]
        let validToken = "AAECAwQFBgcICQoLDA0ODw"
        let validHex = String(repeating: "ab", count: 32)
        let inviteURL = "leaf://invite/\(validToken)?w=Acme&a=\(validHex)"
        let s = "Hey, here's your invite: \(inviteURL) — paste this!"
        let result = ClipboardMatcher.match(s)
        guard case .inviteURL(let url) = result else {
            return XCTFail("expected .inviteURL, got \(result)")
        }
        XCTAssertEqual(url.absoluteString, inviteURL)
    }

    func testMatch_FallsBackToJoinCode() {
        // 76-char formatted JoinCode (no leaf:// URL anywhere).
        let pubkey = Data(repeating: 0xAB, count: 32)
        let joinCode = try! JoinCode.encode(pubkey: pubkey)
        let s = "My Join code:\n\(joinCode)\nHit me up"
        let result = ClipboardMatcher.match(s)
        guard case .joinCode(let decoded) = result else {
            return XCTFail("expected .joinCode, got \(result)")
        }
        XCTAssertEqual(decoded, pubkey)
    }

    func testMatch_AcceptsLegacyHexJoinCode() {
        let pubkeyHex = String(repeating: "ab", count: 32) // 64 hex chars, lowercase
        let result = ClipboardMatcher.match("hi \(pubkeyHex) bye")
        guard case .joinCode(let bytes) = result else {
            return XCTFail("expected .joinCode (legacy hex), got \(result)")
        }
        XCTAssertEqual(bytes.count, 32)
    }

    func testMatch_NoneOnGarbage() {
        let result = ClipboardMatcher.match("just some text 12345")
        if case .none = result { return }
        XCTFail("expected .none, got \(result)")
    }

    func testMatch_NoneOnEmpty() {
        if case .none = ClipboardMatcher.match("") { return }
        XCTFail()
    }

    func testMatch_RejectsWrongSchemeURL() {
        if case .none = ClipboardMatcher.match("https://example.com/invite/foo#bar") { return }
        XCTFail("https URL must not match")
    }
}
