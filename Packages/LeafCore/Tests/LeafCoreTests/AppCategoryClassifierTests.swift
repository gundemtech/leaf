import XCTest
@testable import LeafCore

final class AppCategoryClassifierTests: XCTestCase {
    func testDevBundle_returnsDev() {
        XCTAssertEqual(AppCategoryClassifier.category(for: "com.apple.dt.Xcode"), .dev)
        XCTAssertEqual(AppCategoryClassifier.category(for: "com.microsoft.VSCode"), .dev)
        XCTAssertEqual(AppCategoryClassifier.category(for: "com.googlecode.iterm2"), .dev)
    }

    func testBrowseBundle_returnsBrowse() {
        XCTAssertEqual(AppCategoryClassifier.category(for: "com.apple.Safari"), .browse)
        XCTAssertEqual(AppCategoryClassifier.category(for: "com.google.Chrome"), .browse)
        XCTAssertEqual(AppCategoryClassifier.category(for: "company.thebrowser.Browser"), .browse)
    }

    func testCommunicationBundle_returnsCommunication() {
        XCTAssertEqual(AppCategoryClassifier.category(for: "com.tinyspeck.slackmacgap"), .communication)
        XCTAssertEqual(AppCategoryClassifier.category(for: "ru.keepcoder.Telegram"), .communication)
        XCTAssertEqual(AppCategoryClassifier.category(for: "com.apple.Mail"), .communication)
    }

    func testDesignBundle_returnsDesign() {
        XCTAssertEqual(AppCategoryClassifier.category(for: "com.figma.Desktop"), .design)
        XCTAssertEqual(AppCategoryClassifier.category(for: "com.bohemiancoding.sketch3"), .design)
    }

    func testUnknownBundle_returnsOther() {
        XCTAssertEqual(AppCategoryClassifier.category(for: "io.example.unknown"), .other)
    }

    func testEmptyBundle_returnsOther() {
        XCTAssertEqual(AppCategoryClassifier.category(for: ""), .other)
    }

    func testMalformedBundle_returnsOther() {
        XCTAssertEqual(AppCategoryClassifier.category(for: "not.a.real.bundle.id"), .other)
        XCTAssertEqual(AppCategoryClassifier.category(for: "..."), .other)
    }

    func testCategoryRawValuesAreStable() {
        // Category .rawValue может уйти в DB / config — защита от случайного rename.
        XCTAssertEqual(AppCategory.dev.rawValue, "dev")
        XCTAssertEqual(AppCategory.browse.rawValue, "browse")
        XCTAssertEqual(AppCategory.communication.rawValue, "communication")
        XCTAssertEqual(AppCategory.design.rawValue, "design")
        XCTAssertEqual(AppCategory.other.rawValue, "other")
    }
}
