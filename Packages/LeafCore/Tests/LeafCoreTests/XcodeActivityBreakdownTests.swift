import XCTest
@testable import LeafCore

final class XcodeActivityBreakdownTests: XCTestCase {

    func test_empty_isAllZeros() {
        let empty = XcodeActivityBreakdown.empty
        XCTAssertEqual(empty.buildCount, 0)
        XCTAssertEqual(empty.testRunCount, 0)
        XCTAssertEqual(empty.buildSuccessCount, 0)
        XCTAssertEqual(empty.buildFailureCount, 0)
        XCTAssertEqual(empty.testPassCount, 0)
        XCTAssertEqual(empty.testFailCount, 0)
        XCTAssertTrue(empty.topSchemes.isEmpty)
        XCTAssertTrue(empty.topDestinations.isEmpty)
        XCTAssertTrue(empty.dailyBuilds.isEmpty)
    }

    func test_equatable_roundtrip() {
        let a = XcodeActivityBreakdown(
            buildCount: 12,
            testRunCount: 4,
            buildSuccessCount: 10,
            buildFailureCount: 2,
            testPassCount: 3,
            testFailCount: 1,
            topSchemes: ["Leaf", "LeafAgent"],
            topDestinations: ["macos", "ios_simulator"],
            dailyBuilds: [1, 2, 3, 4, 5, 6, 7]
        )
        let aCopy = XcodeActivityBreakdown(
            buildCount: 12,
            testRunCount: 4,
            buildSuccessCount: 10,
            buildFailureCount: 2,
            testPassCount: 3,
            testFailCount: 1,
            topSchemes: ["Leaf", "LeafAgent"],
            topDestinations: ["macos", "ios_simulator"],
            dailyBuilds: [1, 2, 3, 4, 5, 6, 7]
        )
        let b = XcodeActivityBreakdown(
            buildCount: 99,
            testRunCount: 4,
            buildSuccessCount: 10,
            buildFailureCount: 2,
            testPassCount: 3,
            testFailCount: 1,
            topSchemes: ["Leaf", "LeafAgent"],
            topDestinations: ["macos", "ios_simulator"],
            dailyBuilds: [1, 2, 3, 4, 5, 6, 7]
        )
        XCTAssertEqual(a, aCopy)
        XCTAssertNotEqual(a, b)
    }

    func test_cardPayload_init_assignsFields() {
        let payload = XcodeCardPayload(
            buildCount: 5,
            testRunCount: 2,
            buildSuccessCount: 4,
            buildFailureCount: 1,
            schemesTouchedCount: 3,
            dailyBuilds: [0, 1, 2, 0, 0, 1, 1]
        )
        XCTAssertEqual(payload.buildCount, 5)
        XCTAssertEqual(payload.testRunCount, 2)
        XCTAssertEqual(payload.buildSuccessCount, 4)
        XCTAssertEqual(payload.buildFailureCount, 1)
        XCTAssertEqual(payload.schemesTouchedCount, 3)
        XCTAssertEqual(payload.dailyBuilds.count, 7)
    }

    func test_sendable_acrossTaskBoundary() async {
        let breakdown = XcodeActivityBreakdown.empty
        let echoed = await Task.detached { breakdown }.value
        XCTAssertEqual(echoed, breakdown)
    }
}
