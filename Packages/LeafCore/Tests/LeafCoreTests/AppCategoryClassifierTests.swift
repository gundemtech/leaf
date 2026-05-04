import XCTest
@testable import LeafCore

/// Тесты публичного контракта `AppCategoryClassifier`. Полные preset-bundle
/// тесты живут в `LeafCorePrivateTests` (gitignored) — здесь только то, что
/// гарантирует public LeafCore любому консьюмеру: stable enum raw values +
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
        // Category .rawValue может уйти в DB / config — защита от случайного rename.
        XCTAssertEqual(AppCategory.dev.rawValue, "dev")
        XCTAssertEqual(AppCategory.browse.rawValue, "browse")
        XCTAssertEqual(AppCategory.communication.rawValue, "communication")
        XCTAssertEqual(AppCategory.design.rawValue, "design")
        XCTAssertEqual(AppCategory.other.rawValue, "other")
    }

    func testCategoryAllCases_remainStable() {
        // Order changes сломает downstream UI rendering / migrations.
        XCTAssertEqual(
            AppCategory.allCases,
            [.dev, .browse, .communication, .design, .other]
        )
    }
}
