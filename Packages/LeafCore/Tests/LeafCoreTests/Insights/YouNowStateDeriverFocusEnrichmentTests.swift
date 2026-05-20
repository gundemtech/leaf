import XCTest

@testable import LeafCore

final class YouNowStateDeriverFocusEnrichmentTests: XCTestCase {
    // YouNowInputs.branch/linearID are `let` — construct fresh instances each time.
    private func makeInputs(branch: String? = nil, linearID: String? = nil) -> YouNowInputs {
        YouNowInputs(
            frontmostAppName: "Xcode",
            frontmostBundleID: "com.apple.dt.Xcode",
            contextLabel: "Foo.swift",
            branch: branch,
            linearID: linearID,
            activeSessionStartedAtMs: 1_700_000_000_000,
            intensityBars: 0,
            idleSec: 0,
            screenLocked: false,
            meetingActive: false,
            meetingTitle: nil,
            meetingStartedAtMs: nil,
            meetingEndsAtMs: nil,
            meetingSource: nil,
            focusActive: true,
            focusModeName: "Personal",
            nowMs: 1_700_000_600_000
        )
    }

    func testDeriverPipesBranchAndLinearIDToDeepWorkFocus() {
        let inputs = makeInputs(branch: "feature/leaf-204", linearID: "LEAF-204")
        guard case .deepWorkFocus(let f) = YouNowStateDeriver.derive(inputs) else {
            return XCTFail("expected .deepWorkFocus")
        }
        XCTAssertEqual(f.branch, "feature/leaf-204")
        XCTAssertEqual(f.linearID, "LEAF-204")
    }

    func testDeriverNilBranchYieldsNilFocusBranch() {
        let inputs = makeInputs()  // branch + linearID both nil
        guard case .deepWorkFocus(let f) = YouNowStateDeriver.derive(inputs) else {
            return XCTFail("expected .deepWorkFocus")
        }
        XCTAssertNil(f.branch)
        XCTAssertNil(f.linearID)
    }
}
