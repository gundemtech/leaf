// Phase 5.2.D — InviteOutbound value type tests.

import XCTest

@testable import LeafCore

final class InviteOutboundTests: XCTestCase {

    func testInit_StoresAllFields() {
        let outbound = InviteOutbound(
            token: "abc123token",
            otp: "123456",
            expiresAtMs: 9_999_999_999,
            inviteePubkeyHex: String(repeating: "a", count: 64)
        )

        XCTAssertEqual(outbound.token, "abc123token")
        XCTAssertEqual(outbound.otp, "123456")
        XCTAssertEqual(outbound.expiresAtMs, 9_999_999_999)
        XCTAssertEqual(outbound.inviteePubkeyHex, String(repeating: "a", count: 64))
    }

    func testHashable_DistinctFieldsProduceDistinctValues() {
        let pubkey = String(repeating: "a", count: 64)

        let a = InviteOutbound(
            token: "t1", otp: "111111",
            expiresAtMs: 100, inviteePubkeyHex: pubkey)
        let b = InviteOutbound(
            token: "t1", otp: "111111",
            expiresAtMs: 100, inviteePubkeyHex: pubkey)
        let c = InviteOutbound(
            token: "t2", otp: "111111",
            expiresAtMs: 100, inviteePubkeyHex: pubkey)

        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
        XCTAssertNotEqual(a, c)
    }
}
