import XCTest

@testable import LeafCore

final class YouNowStateDeriverTests: XCTestCase {
    func inputs(
        meetingActive: Bool = false, meetingTitle: String? = nil,
        meetingStartedAtMs: Int64? = nil, meetingEndsAtMs: Int64? = nil,
        meetingSource: MeetingSource? = nil,
        focusActive: Bool = false, focusModeName: String? = nil,
        screenLocked: Bool = false, idleSec: Int = 0,
        frontmostAppName: String? = nil, frontmostBundleID: String? = nil,
        contextLabel: String? = nil, branch: String? = nil, linearID: String? = nil,
        activeSessionStartedAtMs: Int64? = nil, intensityBars: Int = 0,
        nowMs: Int64 = 10_000
    ) -> YouNowInputs {
        YouNowInputs(
            frontmostAppName: frontmostAppName, frontmostBundleID: frontmostBundleID,
            contextLabel: contextLabel, branch: branch, linearID: linearID,
            activeSessionStartedAtMs: activeSessionStartedAtMs, intensityBars: intensityBars,
            idleSec: idleSec, screenLocked: screenLocked,
            meetingActive: meetingActive, meetingTitle: meetingTitle,
            meetingStartedAtMs: meetingStartedAtMs, meetingEndsAtMs: meetingEndsAtMs,
            meetingSource: meetingSource,
            focusActive: focusActive, focusModeName: focusModeName, nowMs: nowMs
        )
    }

    func testMeetingTrumpsEverything() {
        let i = inputs(
            meetingActive: true, meetingTitle: "Standup",
            meetingStartedAtMs: 5000, meetingSource: .eventKit,
            focusActive: true, screenLocked: true, idleSec: 10_000,
            frontmostAppName: "Xcode")
        let s = YouNowStateDeriver.derive(i)
        guard case .inMeeting(let m) = s else { return XCTFail("expected .inMeeting") }
        XCTAssertEqual(m.titleIfAvailable, "Standup")
        XCTAssertEqual(m.source, .eventKit)
        XCTAssertEqual(m.startedAtMs, 5000)
    }

    func testFocusActiveAndRecentBecomesDeepWork() {
        let i = inputs(
            focusActive: true, focusModeName: "Deep work", idleSec: 60,
            frontmostAppName: "Xcode", contextLabel: "HomeView.swift")
        let s = YouNowStateDeriver.derive(i)
        guard case .deepWorkFocus(let f) = s else { return XCTFail("expected .deepWorkFocus") }
        XCTAssertEqual(f.modeName, "Deep work")
        XCTAssertEqual(f.app, "Xcode")
    }

    func testFocusActiveButIdleFallsThroughToAway() {
        let i = inputs(focusActive: true, focusModeName: "Deep work", idleSec: 400)
        let s = YouNowStateDeriver.derive(i)
        guard case .away(let a) = s else { return XCTFail("expected .away") }
        XCTAssertEqual(a.reason, .idle)
    }

    func testScreenLockedBecomesAwayScreenLocked() {
        let i = inputs(
            screenLocked: true, idleSec: 0, frontmostAppName: "Xcode",
            linearID: "LEAF-1")
        let s = YouNowStateDeriver.derive(i)
        guard case .away(let a) = s else { return XCTFail("expected .away") }
        XCTAssertEqual(a.reason, .screenLocked)
        XCTAssertEqual(a.lastApp, "Xcode")
        XCTAssertEqual(a.lastLinearID, "LEAF-1")
    }

    func testIdleAboveThresholdBecomesAwayIdle() {
        let i = inputs(idleSec: 600, frontmostAppName: "Xcode")
        let s = YouNowStateDeriver.derive(i)
        guard case .away(let a) = s else { return XCTFail("expected .away") }
        XCTAssertEqual(a.reason, .idle)
    }

    func testFrontmostAppRecentBecomesActive() {
        let i = inputs(
            idleSec: 30, frontmostAppName: "Xcode",
            contextLabel: "HomeView.swift", branch: "feature/track-8",
            linearID: "LEAF-204", activeSessionStartedAtMs: 1000,
            intensityBars: 2, nowMs: 121_000)
        let s = YouNowStateDeriver.derive(i)
        guard case .active(let act) = s else { return XCTFail("expected .active") }
        XCTAssertEqual(act.app, "Xcode")
        XCTAssertEqual(act.linearID, "LEAF-204")
        XCTAssertEqual(act.intensityBars, 2)
        XCTAssertEqual(act.durationSec, 120)
    }

    func testCustomIdleThreshold() {
        let i = inputs(idleSec: 59, frontmostAppName: "Xcode")
        if case .active = YouNowStateDeriver.derive(i, idleThresholdSec: 60) {
            // ok
        } else {
            XCTFail("expected .active at idle=59 below threshold=60")
        }
        let i2 = inputs(idleSec: 60, frontmostAppName: "Xcode")
        if case .away = YouNowStateDeriver.derive(i2, idleThresholdSec: 60) {
            // ok
        } else {
            XCTFail("expected .away at idle=60 == threshold")
        }
    }

    func testActivePreservesFields() {
        let i = inputs(
            idleSec: 0, frontmostAppName: "Xcode", contextLabel: "F.swift",
            branch: "feat", linearID: "LEAF-1", activeSessionStartedAtMs: nil,
            intensityBars: 4)
        let s = YouNowStateDeriver.derive(i)
        guard case .active(let act) = s else { return XCTFail() }
        XCTAssertEqual(act.contextLabel, "F.swift")
        XCTAssertEqual(act.branch, "feat")
        XCTAssertEqual(act.intensityBars, 4)
        XCTAssertEqual(act.durationSec, 0)
    }

    func testMeetingFieldsPropagate() {
        let i = inputs(
            meetingActive: true, meetingTitle: "Q",
            meetingStartedAtMs: 3000, meetingEndsAtMs: 4000,
            meetingSource: .zoom)
        let s = YouNowStateDeriver.derive(i)
        guard case .inMeeting(let m) = s else { return XCTFail() }
        XCTAssertEqual(m.titleIfAvailable, "Q")
        XCTAssertEqual(m.startedAtMs, 3000)
        XCTAssertEqual(m.endsAtMsIfAvailable, 4000)
        XCTAssertEqual(m.source, .zoom)
    }

    func testDegenerateNothingCaptured() {
        let i = inputs()
        let s = YouNowStateDeriver.derive(i)
        guard case .away(let a) = s else { return XCTFail() }
        XCTAssertEqual(a.reason, .idle)
        XCTAssertNil(a.lastApp)
        XCTAssertEqual(a.idleSec, 0)
    }
}
