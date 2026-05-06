import XCTest
@testable import LeafCore

final class RotationFetchOutcomeTests: XCTestCase {

    func testEquatableRoundTrip() {
        let a = RotationFetchOutcome(fetched: 3, installed: 1, tombstoneApplied: 1, skipped: 1)
        let b = RotationFetchOutcome(fetched: 3, installed: 1, tombstoneApplied: 1, skipped: 1)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func testEmptyStaticIsAllZero() {
        let e = RotationFetchOutcome.empty
        XCTAssertEqual(e.fetched, 0)
        XCTAssertEqual(e.installed, 0)
        XCTAssertEqual(e.tombstoneApplied, 0)
        XCTAssertEqual(e.skipped, 0)
    }

    func testDistinctValuesHashDistinct() {
        let a = RotationFetchOutcome(fetched: 1, installed: 0, tombstoneApplied: 0, skipped: 0)
        let b = RotationFetchOutcome(fetched: 0, installed: 1, tombstoneApplied: 0, skipped: 0)
        XCTAssertNotEqual(a, b)
    }
}
