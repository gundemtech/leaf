import XCTest

@testable import LeafCore

final class ModeClassifierTests: XCTestCase {
    func testModeRawValues() {
        XCTAssertEqual(Mode.code.rawValue, "code")
        XCTAssertEqual(Mode.coordination.rawValue, "coordination")
        XCTAssertEqual(Mode.review.rawValue, "review")
        XCTAssertEqual(Mode.focus.rawValue, "focus")
        XCTAssertEqual(Mode.meeting.rawValue, "meeting")
    }

    func testPulseRawValues() {
        XCTAssertEqual(Pulse.heavy.rawValue, "heavy")
        XCTAssertEqual(Pulse.medium.rawValue, "medium")
        XCTAssertEqual(Pulse.light.rawValue, "light")
    }

    func testClassifiedModeStorage() {
        let cm = ClassifiedMode(
            mode: .review,
            pulse: .medium,
            confidence: 0.8,
            observedAtMs: 1_700_000_000_000
        )
        XCTAssertEqual(cm.mode, .review)
        XCTAssertEqual(cm.pulse, .medium)
        XCTAssertEqual(cm.confidence, 0.8)
        XCTAssertEqual(cm.observedAtMs, 1_700_000_000_000)
    }

    func testModeAllCases() {
        XCTAssertEqual(Mode.allCases.count, 5)
    }

    func testPulseAllCases() {
        XCTAssertEqual(Pulse.allCases.count, 3)
    }
}
