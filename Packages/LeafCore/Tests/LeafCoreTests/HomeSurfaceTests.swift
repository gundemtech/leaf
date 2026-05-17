// Packages/LeafCore/Tests/LeafCoreTests/HomeSurfaceTests.swift
import XCTest
@testable import LeafCore

final class HomeSurfaceTests: XCTestCase {

    /// Track 7 contract §3 — ordering is the static array driving Home's
    /// enabled / disabled partitioned render. Changing this list breaks the
    /// surface card render plan. Pin the order via test.
    func testCatalogOrderingMatchesSpec() {
        XCTAssertEqual(
            SurfaceCatalog.all,
            [.claudeCode, .xcode, .ides, .browsers, .zoom, .calendar]
        )
    }

    func testAllCasesMatchesCatalog() {
        XCTAssertEqual(HomeSurface.allCases, SurfaceCatalog.all)
    }

    func testRawValuesAreStable() {
        XCTAssertEqual(HomeSurface.claudeCode.rawValue, "claudeCode")
        XCTAssertEqual(HomeSurface.xcode.rawValue,      "xcode")
        XCTAssertEqual(HomeSurface.ides.rawValue,       "ides")
        XCTAssertEqual(HomeSurface.browsers.rawValue,   "browsers")
        XCTAssertEqual(HomeSurface.zoom.rawValue,       "zoom")
        XCTAssertEqual(HomeSurface.calendar.rawValue,   "calendar")
    }

    func testDisplayNamesAreNonEmpty() {
        for surface in HomeSurface.allCases {
            XCTAssertFalse(surface.displayName.isEmpty, "missing displayName for \(surface)")
        }
    }

    func testLocalizationKeyPrefix() {
        for surface in HomeSurface.allCases {
            XCTAssertTrue(
                surface.localizationKey.hasPrefix("home.surface."),
                "wrong key prefix: \(surface.localizationKey)"
            )
        }
    }
}
