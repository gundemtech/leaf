import XCTest

@testable import LeafCore

/// Track-9 T6 — `PillFamily` enum is the canonical namespace for TODAY pills:
/// 13 cases (10 capture-time + 3 action-noun) per master spec scope lock #6.
/// `rawValue` alignment with `HomeSurface` / `LayerBProvider` enables zero-cost
/// routing through existing `SurfacePillRouter`.
final class PillFamilyTests: XCTestCase {
    func test_allCases_count_equals_13() {
        XCTAssertEqual(PillFamily.allCases.count, 13)
    }

    func test_captureFamilies_haveCaptureTimeKind() {
        let captureFamilies: [PillFamily] = [
            .claudeCode, .xcode, .ides, .browsers, .zoom, .calendar,
            .mail, .notes, .music, .reminders,
        ]
        for family in captureFamilies {
            XCTAssertEqual(family.kind, .captureTime, "\(family) should be capture-time")
        }
    }

    func test_layerBProviders_haveActionNounKind() {
        let layerB: [PillFamily] = [.linear, .github, .slack]
        for family in layerB {
            XCTAssertEqual(family.kind, .actionNoun, "\(family) should be action-noun")
        }
    }

    func test_displayName_nonEmpty_forAllFamilies() {
        for family in PillFamily.allCases {
            XCTAssertFalse(family.displayName.isEmpty, "\(family) has empty displayName")
        }
    }

    func test_rawValue_alignsWithHomeSurface_forCaptureSurfaces() {
        // 6 capture surfaces share rawValue with HomeSurface — enables router pass-through.
        XCTAssertEqual(PillFamily.claudeCode.rawValue, HomeSurface.claudeCode.rawValue)
        XCTAssertEqual(PillFamily.xcode.rawValue, HomeSurface.xcode.rawValue)
        XCTAssertEqual(PillFamily.ides.rawValue, HomeSurface.ides.rawValue)
        XCTAssertEqual(PillFamily.browsers.rawValue, HomeSurface.browsers.rawValue)
        XCTAssertEqual(PillFamily.zoom.rawValue, HomeSurface.zoom.rawValue)
        XCTAssertEqual(PillFamily.calendar.rawValue, HomeSurface.calendar.rawValue)
    }

    func test_rawValue_alignsWithLayerBProvider_forLayerBFamilies() {
        XCTAssertEqual(PillFamily.linear.rawValue, LayerBProvider.linear.rawValue)
        XCTAssertEqual(PillFamily.github.rawValue, LayerBProvider.github.rawValue)
        XCTAssertEqual(PillFamily.slack.rawValue, LayerBProvider.slack.rawValue)
    }
}
