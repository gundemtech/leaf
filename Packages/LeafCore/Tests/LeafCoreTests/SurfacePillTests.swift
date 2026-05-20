import XCTest

@testable import LeafCore

/// Track-9 T6 — SurfacePill kind discriminator. `.captureTime` carries duration
/// in seconds (UI renders "Xh Ym"); `.actionNoun` carries discrete event count
/// (UI renders "N"). NO default on `kind` — explicit at all construction sites.
final class SurfacePillTests: XCTestCase {
    func test_captureTime_initializesWithSeconds() {
        let pill = SurfacePill(id: "claudeCode", label: "Claude", count: 4860, kind: .captureTime)
        XCTAssertEqual(pill.id, "claudeCode")
        XCTAssertEqual(pill.label, "Claude")
        XCTAssertEqual(pill.count, 4860)
        XCTAssertEqual(pill.kind, .captureTime)
    }

    func test_actionNoun_initializesWithCount() {
        let pill = SurfacePill(id: "linear", label: "Linear", count: 3, kind: .actionNoun)
        XCTAssertEqual(pill.kind, .actionNoun)
        XCTAssertEqual(pill.count, 3)
    }

    func test_kindDiscriminator_distinguishesEquality() {
        let captureTimePill = SurfacePill(id: "xcode", label: "Xcode", count: 7, kind: .captureTime)
        let actionNounPill = SurfacePill(id: "xcode", label: "Xcode", count: 7, kind: .actionNoun)
        XCTAssertNotEqual(captureTimePill, actionNounPill)
    }

    func test_sameKind_sameFields_areEqual() {
        let a = SurfacePill(id: "github", label: "GitHub", count: 2, kind: .actionNoun)
        let b = SurfacePill(id: "github", label: "GitHub", count: 2, kind: .actionNoun)
        XCTAssertEqual(a, b)
    }
}
