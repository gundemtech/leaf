import XCTest
@testable import LeafCore

final class IDETitlePathSanitizerTests: XCTestCase {

    func test_replacesHomeDir() {
        let raw = NSHomeDirectory() + "/Desktop/secret/project"
        let sanitized = IDETitlePathSanitizer.sanitize(raw)
        XCTAssertFalse(sanitized.contains(NSHomeDirectory()))
        XCTAssertTrue(sanitized.contains("~/"))
    }

    func test_takesBasenameOfPathTokens() {
        let input = "Foo.swift — /Users/alice/secret/project — Visual Studio Code"
        let sanitized = IDETitlePathSanitizer.sanitize(input)
        XCTAssertFalse(sanitized.contains("alice"))
        XCTAssertFalse(sanitized.contains("/secret"))
        XCTAssertTrue(sanitized.contains("project"))
    }

    func test_leavesNonPathTokensUnchanged() {
        let sanitized = IDETitlePathSanitizer.sanitize("Foo.swift — leaf — Visual Studio Code")
        XCTAssertEqual(sanitized, "Foo.swift — leaf — Visual Studio Code")
    }

    func test_handlesEmptyAndWhitespace() {
        XCTAssertEqual(IDETitlePathSanitizer.sanitize(""), "")
        XCTAssertEqual(IDETitlePathSanitizer.sanitize("   "), "   ")
    }

    func test_truncatesAt200Chars() {
        let long = String(repeating: "a", count: 500)
        let sanitized = IDETitlePathSanitizer.sanitize(long)
        XCTAssertLessThanOrEqual(sanitized.count, 200)
    }
}
