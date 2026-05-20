import XCTest

@testable import LeafCore

final class YouNowFocusEnrichmentTests: XCTestCase {
    func testYouNowFocusEquatableRoundTrip() {
        let f = YouNowFocus(
            modeName: "Personal",
            app: "Xcode",
            contextLabel: "Foo.swift",
            durationSec: 600,
            branch: "feature/leaf-204",
            linearID: "LEAF-204")
        XCTAssertEqual(f, f)
        XCTAssertEqual(f.branch, "feature/leaf-204")
        XCTAssertEqual(f.linearID, "LEAF-204")
    }

    func testYouNowFocusDefaultedInitPreservesExistingCallsites() {
        // Legacy init (without branch/linearID) must still compile and default to nil.
        let f = YouNowFocus(
            modeName: nil, app: "Xcode", contextLabel: nil, durationSec: 300)
        XCTAssertNil(f.branch)
        XCTAssertNil(f.linearID)
    }

    func testYouNowFocusBranchLinearIDHashable() {
        let f1 = YouNowFocus(
            modeName: nil, app: nil, contextLabel: nil, durationSec: 0,
            branch: "a", linearID: "LEAF-1")
        let f2 = YouNowFocus(
            modeName: nil, app: nil, contextLabel: nil, durationSec: 0,
            branch: "a", linearID: "LEAF-1")
        XCTAssertEqual(Set<YouNowFocus>([f1, f2]).count, 1)
    }
}
