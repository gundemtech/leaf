// Phase 5.3.C — RotationToken value type tests.

import XCTest
@testable import LeafCore

final class RotationTokenTests: XCTestCase {

    func testInit_PreservesFields() {
        let token = RotationToken(value: "rot_abc123", expiresAtMs: 1_700_000_000_000)
        XCTAssertEqual(token.value, "rot_abc123")
        XCTAssertEqual(token.expiresAtMs, 1_700_000_000_000)
    }

    func testEquatable_SameFieldsEqual() {
        let a = RotationToken(value: "x", expiresAtMs: 1)
        let b = RotationToken(value: "x", expiresAtMs: 1)
        XCTAssertEqual(a, b)
    }

    func testEquatable_DifferentFieldsNotEqual() {
        let a = RotationToken(value: "x", expiresAtMs: 1)
        let b = RotationToken(value: "y", expiresAtMs: 1)
        XCTAssertNotEqual(a, b)
    }

    func testHashable_UseableInSet() {
        let token = RotationToken(value: "x", expiresAtMs: 1)
        let set: Set<RotationToken> = [token]
        XCTAssertTrue(set.contains(token))
    }
}
