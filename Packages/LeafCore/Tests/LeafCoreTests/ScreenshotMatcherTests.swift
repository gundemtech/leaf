import XCTest

@testable import LeafCore

final class ScreenshotMatcherTests: XCTestCase {

    private let matcher = ScreenshotMatcher()

    func testEnglishScreenshotPng() {
        XCTAssertTrue(matcher.matches(filename: "Screenshot 2026-05-13 at 10.42.13.png"))
    }

    func testEnglishScreenShotLegacy() {
        XCTAssertTrue(matcher.matches(filename: "Screen Shot 2024-01-01 at 12.00.00.png"))
    }

    func testRussianSnimokEkrana() {
        XCTAssertTrue(matcher.matches(filename: "Снимок экрана 2026-05-13.png"))
    }

    func testGermanBildschirm() {
        XCTAssertTrue(matcher.matches(filename: "Bildschirmfoto 2024.png"))
    }

    func testFrenchCaptureDecran() {
        XCTAssertTrue(matcher.matches(filename: "Capture d'écran 2024.png"))
    }

    func testSpanishCapturaDePantalla() {
        XCTAssertTrue(matcher.matches(filename: "Captura de pantalla 2024.png"))
    }

    func testJapaneseScreenshot() {
        XCTAssertTrue(matcher.matches(filename: "スクリーンショット 2024.png"))
    }

    func testKoreanScreenshot() {
        XCTAssertTrue(matcher.matches(filename: "스크린샷 2024.png"))
    }

    func testItalianCatturaSchermata() {
        XCTAssertTrue(matcher.matches(filename: "Cattura schermata 2024.png"))
    }

    func testRandomFilenameRejected() {
        XCTAssertFalse(matcher.matches(filename: "todo.png"))
        XCTAssertFalse(matcher.matches(filename: "design-final.png"))
    }

    func testScreenshotWithDisallowedExtensionRejected() {
        XCTAssertFalse(matcher.matches(filename: "Screenshot.txt"))
        XCTAssertFalse(matcher.matches(filename: "Screenshot.app"))
    }

    func testCustomAdditionalPrefix() {
        let custom = ScreenshotMatcher(additionalPrefixes: ["MyShot"])
        XCTAssertTrue(custom.matches(filename: "MyShot 2024.png"))
        XCTAssertFalse(
            matcher.matches(filename: "MyShot 2024.png"),
            "default matcher must not recognise custom prefix")
    }
}
