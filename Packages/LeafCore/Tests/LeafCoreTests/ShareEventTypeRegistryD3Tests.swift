import XCTest
@testable import LeafCore

final class ShareEventTypeRegistryD3Tests: XCTestCase {
    func testFiveD3KeysRegisteredAfterTrack3D1() {
        let allKeys = Set(ShareEventTypeKey.allCases.map(\.rawValue))
        let d3 = ["decision_detected", "open_question_opened",
                  "open_question_resolved", "blocker_started", "blocker_resolved"]
        for key in d3 {
            XCTAssertTrue(allKeys.contains(key), "Missing D3 key \(key)")
        }
        // Track-3 D1 grew registry 48 → 66 (18 Linear deep-sweep kinds).
        // Track-3 D2 grew registry 66 → 97 (31 GitHub deep-sweep kinds).
        // Track-3 D3 grew registry 97 → 116 (19 Slack deep-sweep kinds).
        // Track-4 S1 grew 116 → 125 (9 architecture catch-up kinds).
        // Track-4 S2 grew 125 → 139. Track-4 S3 grew 139 → 152.
        // Track-6 P1 grew 152 → 168 (16 Claude Code deep kinds).
        // Track-6 P2 grew 168 → 174 (6 Xcode Deep kinds). Track-6 P3 grew 174 → 182 (8 Browsers Deep kinds).
        // Track-6 P5 grew 182 → 185 (3 Zoom Deep kinds).
        // D3 keys' presence above is the core invariant; size is sanity-only.
        XCTAssertEqual(ShareEventTypeKey.allCases.count, 192)
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
