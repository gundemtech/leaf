import XCTest

@testable import LeafCore

/// Track 8 / Phase 8.3 — TODAY pill ID → navigation route mapping. Verifies
/// `SurfacePill.id` strings emitted by `ProdInsights+TodayMetrics` resolve to
/// the correct push-target enum case (or `nil` for unknown IDs).
final class SurfacePillRouterTests: XCTestCase {
    func test_knownCaptureSurface_returnsHomeSurfaceRoute() {
        XCTAssertEqual(SurfacePillRouter.route(forPillID: "xcode"), .homeSurface(.xcode))
        XCTAssertEqual(SurfacePillRouter.route(forPillID: "claudeCode"), .homeSurface(.claudeCode))
    }

    func test_knownLayerBProvider_returnsLayerBRoute() {
        XCTAssertEqual(SurfacePillRouter.route(forPillID: "linear"), .layerBProvider(.linear))
        XCTAssertEqual(SurfacePillRouter.route(forPillID: "slack"), .layerBProvider(.slack))
    }

    func test_unknownID_returnsNil() {
        XCTAssertNil(SurfacePillRouter.route(forPillID: "fortnite"))
    }

    func test_emptyString_returnsNil() {
        XCTAssertNil(SurfacePillRouter.route(forPillID: ""))
    }

    // MARK: - Track-9 T6 — PillFamily.rawValue routing parity

    func test_pillFamily_claudeCode_routesToHomeSurface() {
        XCTAssertEqual(
            SurfacePillRouter.route(forPillID: PillFamily.claudeCode.rawValue),
            .homeSurface(.claudeCode)
        )
    }

    func test_pillFamily_linear_routesToLayerB() {
        XCTAssertEqual(
            SurfacePillRouter.route(forPillID: PillFamily.linear.rawValue),
            .layerBProvider(.linear)
        )
    }

    func test_pillFamily_mail_returnsNil() {
        XCTAssertNil(SurfacePillRouter.route(forPillID: PillFamily.mail.rawValue))
    }

    func test_pillFamily_notes_returnsNil() {
        XCTAssertNil(SurfacePillRouter.route(forPillID: PillFamily.notes.rawValue))
    }

    func test_pillFamily_music_returnsNil() {
        XCTAssertNil(SurfacePillRouter.route(forPillID: PillFamily.music.rawValue))
    }

    func test_pillFamily_reminders_returnsNil() {
        XCTAssertNil(SurfacePillRouter.route(forPillID: PillFamily.reminders.rawValue))
    }
}
