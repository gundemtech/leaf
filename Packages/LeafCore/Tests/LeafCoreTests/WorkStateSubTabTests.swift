import XCTest
@testable import LeafCore

final class WorkStateSubTabTests: XCTestCase {
    func testAllCases_order() {
        // Mockup order: Decisions / Questions / Blockers / Where Stopped.
        XCTAssertEqual(WorkStateSubTab.allCases, [
            .decisions, .questions, .blockers, .whereStopped
        ])
    }

    func testRawValues_stableForUserDefaultsAndRoutingKeys() {
        XCTAssertEqual(WorkStateSubTab.decisions.rawValue,   "decisions")
        XCTAssertEqual(WorkStateSubTab.questions.rawValue,   "questions")
        XCTAssertEqual(WorkStateSubTab.blockers.rawValue,    "blockers")
        XCTAssertEqual(WorkStateSubTab.whereStopped.rawValue, "where_stopped")
    }

    func testIdentifiable_idIsRawValue() {
        XCTAssertEqual(WorkStateSubTab.questions.id, "questions")
    }

    func testDisplayName_perCase() {
        XCTAssertEqual(WorkStateSubTab.decisions.displayName,   "Decisions")
        XCTAssertEqual(WorkStateSubTab.questions.displayName,   "Questions")
        XCTAssertEqual(WorkStateSubTab.blockers.displayName,    "Blockers")
        XCTAssertEqual(WorkStateSubTab.whereStopped.displayName, "Where Stopped")
    }

    func testHashable_insertableIntoSet() {
        let set: Set<WorkStateSubTab> = [.decisions, .questions, .decisions]
        XCTAssertEqual(set.count, 2)
    }

    func testSendable() {
        let _: any Sendable = WorkStateSubTab.questions
    }
}
