import XCTest

@testable import LeafCore

final class WorkStateSummaryTests: XCTestCase {
    func testEmpty_zerosAndNils() {
        let s = WorkStateSummary.empty
        XCTAssertEqual(s.openQuestionsCount, 0)
        XCTAssertEqual(s.openBlockersCount, 0)
        XCTAssertNil(s.lastDecisionExcerpt)
        XCTAssertNil(s.lastDecisionAgeMs)
    }

    func testMemberwiseInit() {
        let s = WorkStateSummary(
            openQuestionsCount: 3,
            openBlockersCount: 1,
            lastDecisionExcerpt: "Use SQLite WAL",
            lastDecisionAgeMs: 7_200_000
        )
        XCTAssertEqual(s.openQuestionsCount, 3)
        XCTAssertEqual(s.openBlockersCount, 1)
        XCTAssertEqual(s.lastDecisionExcerpt, "Use SQLite WAL")
        XCTAssertEqual(s.lastDecisionAgeMs, 7_200_000)
    }

    func testHashable() {
        let a = WorkStateSummary(
            openQuestionsCount: 1, openBlockersCount: 0,
            lastDecisionExcerpt: nil, lastDecisionAgeMs: nil)
        let b = WorkStateSummary(
            openQuestionsCount: 1, openBlockersCount: 0,
            lastDecisionExcerpt: nil, lastDecisionAgeMs: nil)
        XCTAssertEqual(Set([a, b]).count, 1)
    }

    func testSendableConformance() {
        let _: any Sendable = WorkStateSummary.empty
    }
}
