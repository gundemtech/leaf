// Phase 5.3.C — RotationFetched value type tests.

import XCTest
@testable import LeafCore

final class RotationFetchedTests: XCTestCase {

    func testInit_PreservesFields() {
        let blob = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let fetched = RotationFetched(rotationID: "rot_xyz",
                                      blob: blob,
                                      expiresAtMs: 1_700_000_000_000)
        XCTAssertEqual(fetched.rotationID, "rot_xyz")
        XCTAssertEqual(fetched.blob, blob)
        XCTAssertEqual(fetched.expiresAtMs, 1_700_000_000_000)
    }

    func testEquatable_SameFieldsEqual() {
        let a = RotationFetched(rotationID: "x", blob: Data([0x01]), expiresAtMs: 1)
        let b = RotationFetched(rotationID: "x", blob: Data([0x01]), expiresAtMs: 1)
        XCTAssertEqual(a, b)
    }

    func testEquatable_DifferentBlobNotEqual() {
        let a = RotationFetched(rotationID: "x", blob: Data([0x01]), expiresAtMs: 1)
        let b = RotationFetched(rotationID: "x", blob: Data([0x02]), expiresAtMs: 1)
        XCTAssertNotEqual(a, b)
    }

    func testHashable_UseableInSet() {
        let f = RotationFetched(rotationID: "x", blob: Data([0x01]), expiresAtMs: 1)
        let set: Set<RotationFetched> = [f]
        XCTAssertTrue(set.contains(f))
    }
}
