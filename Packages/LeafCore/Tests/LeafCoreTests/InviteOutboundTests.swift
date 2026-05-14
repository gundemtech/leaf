// Track 5 / S3 — InviteOutbound value type tests.

import XCTest
@testable import LeafCore

final class InviteOutboundTests: XCTestCase {

    private let sampleURL = URL(string: "leaf://invite/AAECAwQFBgcICQoLDA0ODw?w=Acme&a=\(String(repeating: "ab", count: 32))")!
    private let sampleURLWithOTP = URL(string: "leaf://invite/AAECAwQFBgcICQoLDA0ODw?w=Acme&a=\(String(repeating: "ab", count: 32))#123456")!

    func testInit_StoresAllFields() {
        let outbound = InviteOutbound(
            token: "AAECAwQFBgcICQoLDA0ODw",
            url: sampleURLWithOTP,
            otp: "123456",
            expiresAtMs: 9_999_999_999,
            inviteePubkeyHex: String(repeating: "a", count: 64)
        )

        XCTAssertEqual(outbound.token, "AAECAwQFBgcICQoLDA0ODw")
        XCTAssertEqual(outbound.url, sampleURLWithOTP)
        XCTAssertEqual(outbound.otp, "123456")
        XCTAssertEqual(outbound.expiresAtMs, 9_999_999_999)
        XCTAssertEqual(outbound.inviteePubkeyHex, String(repeating: "a", count: 64))
    }

    func testInit_NoOTP_otpIsNil() {
        let outbound = InviteOutbound(
            token: "AAECAwQFBgcICQoLDA0ODw",
            url: sampleURL,
            otp: nil,
            expiresAtMs: 100,
            inviteePubkeyHex: String(repeating: "a", count: 64)
        )
        XCTAssertNil(outbound.otp)
    }

    func testHashable_DistinctFieldsProduceDistinctValues() {
        let pubkey = String(repeating: "a", count: 64)

        let a = InviteOutbound(token: "t1", url: sampleURL, otp: "111111",
                               expiresAtMs: 100, inviteePubkeyHex: pubkey)
        let b = InviteOutbound(token: "t1", url: sampleURL, otp: "111111",
                               expiresAtMs: 100, inviteePubkeyHex: pubkey)
        let c = InviteOutbound(token: "t2", url: sampleURL, otp: "111111",
                               expiresAtMs: 100, inviteePubkeyHex: pubkey)

        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
        XCTAssertNotEqual(a, c)
    }
}
