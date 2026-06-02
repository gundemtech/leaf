import XCTest
@testable import LeafCore

/// Tests for the public contract of `AppCategoryClassifier`. The full
/// preset-bundle tests live in `LeafCorePrivateTests` (gitignored) — here only
/// what public LeafCore guarantees to any consumer: stable enum raw values +
/// EmptyAppCategoryClassifier safety floor.
final class AppCategoryClassifierTests: XCTestCase {
    func testEmptyClassifier_anyBundle_returnsOther() {
        let classifier = EmptyAppCategoryClassifier()
        XCTAssertEqual(classifier.category(for: "com.apple.dt.Xcode"), .other)
        XCTAssertEqual(classifier.category(for: "com.apple.Safari"), .other)
        XCTAssertEqual(classifier.category(for: ""), .other)
        XCTAssertEqual(classifier.category(for: "io.example.unknown"), .other)
    }

    func testCategoryRawValuesAreStable() {
        // Category .rawValue may end up in DB / config — guard against accidental rename.
        XCTAssertEqual(AppCategory.dev.rawValue, "dev")
        XCTAssertEqual(AppCategory.browse.rawValue, "browse")
        XCTAssertEqual(AppCategory.communication.rawValue, "communication")
        XCTAssertEqual(AppCategory.design.rawValue, "design")
        XCTAssertEqual(AppCategory.other.rawValue, "other")
    }

    func testCategoryAllCases_remainStable() {
        // Order changes will break downstream UI rendering / migrations.
        XCTAssertEqual(
            AppCategory.allCases,
            [.dev, .browse, .communication, .design, .other]
        )
    }
}
