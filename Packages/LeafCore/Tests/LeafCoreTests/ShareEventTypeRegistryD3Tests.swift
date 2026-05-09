import XCTest
@testable import LeafCore

final class ShareEventTypeRegistryD3Tests: XCTestCase {
    func testFiveD3KeysRegisteredTotalIs48() {
        let allKeys = Set(ShareEventTypeKey.allCases.map(\.rawValue))
        let d3 = ["decision_detected", "open_question_opened",
                  "open_question_resolved", "blocker_started", "blocker_resolved"]
        for key in d3 {
            XCTAssertTrue(allKeys.contains(key), "Missing D3 key \(key)")
        }
        XCTAssertEqual(ShareEventTypeKey.allCases.count, 48)
    }

    func testAllD3KeysDefaultOff() {
        let d3: Set<ShareEventTypeKey> = [.decisionDetected,
                                           .openQuestionOpened,
                                           .openQuestionResolved,
                                           .blockerStarted,
                                           .blockerResolved]
        for entry in ShareEventTypeDefaults.all where d3.contains(entry.key) {
            XCTAssertFalse(entry.defaultEnabled,
                "D3 key \(entry.key.rawValue) should default OFF (semantic fact)")
        }
    }
}
