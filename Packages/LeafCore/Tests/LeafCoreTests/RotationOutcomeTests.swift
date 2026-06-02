import XCTest
@testable import LeafCore

/// Phase 5.3.D — `RotationOutcome` return type for `removeMember` + `resumePendingPosts`.
final class RotationOutcomeTests: XCTestCase {

    func testEquatableHashableRoundTrip() {
        let a = RotationOutcome(newKeyID: "k1", priorKeyID: "k0", postedCount: 2, pendingCount: 1, totalCount: 3)
        let b = a
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func testEmptyResumePendingShape() {
        let empty = RotationOutcome(newKeyID: "", priorKeyID: "", postedCount: 0, pendingCount: 0, totalCount: 0)
        XCTAssertEqual(empty.totalCount, 0)
        XCTAssertEqual(empty.postedCount + empty.pendingCount, empty.totalCount)
    }
}
