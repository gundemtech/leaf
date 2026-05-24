import XCTest
@testable import LeafCore

final class YouNowStateTests: XCTestCase {
    func testActiveCase() {
        let a = YouNowActive(app: "Xcode", contextLabel: "HomeView.swift", branch: "feat",
                             linearID: "LEAF-1", durationSec: 60, intensityBars: 3)
        let s = YouNowState.active(a)
        guard case .active(let x) = s else { return XCTFail("expected .active") }
        XCTAssertEqual(x.app, "Xcode")
        XCTAssertEqual(x.intensityBars, 3)
    }

    func testInMeetingCase() {
        let m = YouNowMeeting(titleIfAvailable: "Standup", startedAtMs: 1000,
                              endsAtMsIfAvailable: 2000, source: .eventKit)
        let s = YouNowState.inMeeting(m)
        guard case .inMeeting(let x) = s else { return XCTFail("expected .inMeeting") }
        XCTAssertEqual(x.source, .eventKit)
    }

    func testDeepWorkCase() {
        let f = YouNowFocus(modeName: "Deep work", app: "Xcode", contextLabel: nil, durationSec: 300)
        let s = YouNowState.deepWorkFocus(f)
        guard case .deepWorkFocus(let x) = s else { return XCTFail("expected .deepWorkFocus") }
        XCTAssertEqual(x.modeName, "Deep work")
    }

    func testAwayCase() {
        let a = YouNowAway(reason: .screenLocked, lastApp: "Xcode", lastContextLabel: nil,
                           lastLinearID: "LEAF-1", idleSec: 600)
        let s = YouNowState.away(a)
        guard case .away(let x) = s else { return XCTFail("expected .away") }
        XCTAssertEqual(x.reason, .screenLocked)
    }

    func testMeetingSourceValues() {
        XCTAssertEqual(MeetingSource.eventKit.rawValue, "eventKit")
        XCTAssertEqual(MeetingSource.zoom.rawValue, "zoom")
        XCTAssertEqual(MeetingSource.both.rawValue, "both")
    }

    func testAwayReasonValues() {
        XCTAssertEqual(AwayReason.screenLocked.rawValue, "screenLocked")
        XCTAssertEqual(AwayReason.idle.rawValue, "idle")
        XCTAssertEqual(AwayReason.sleep.rawValue, "sleep")
    }

    func testEquatable() {
        let a1 = YouNowActive(app: "X", contextLabel: nil, branch: nil, linearID: nil,
                              durationSec: 0, intensityBars: 0)
        let a2 = YouNowActive(app: "X", contextLabel: nil, branch: nil, linearID: nil,
                              durationSec: 0, intensityBars: 0)
        XCTAssertEqual(YouNowState.active(a1), YouNowState.active(a2))
    }
}
