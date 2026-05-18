import XCTest

@testable import LeafCore

final class ClaudeCodeHeadlineFormatterTests: XCTestCase {

    /// Spec OQ-T7-2 — K/M/B thresholds:
    ///   below 1_000          → "{N} tokens" (no separator)
    ///   1_000 ..< 1_000_000  → "{N}K tokens" (1-digit precision)
    ///   1_000_000 ..< 1e9    → "{N}M tokens"
    ///   1e9 and above        → "{N}B tokens"

    func testZeroTokens() {
        XCTAssertEqual(ClaudeCodeHeadlineFormatter.tokens(0), "0 tokens")
    }

    func testSubThousand() {
        XCTAssertEqual(ClaudeCodeHeadlineFormatter.tokens(812), "812 tokens")
    }

    func testKThreshold() {
        XCTAssertEqual(ClaudeCodeHeadlineFormatter.tokens(52_300), "52.3K tokens")
    }

    func testMThreshold() {
        XCTAssertEqual(ClaudeCodeHeadlineFormatter.tokens(2_100_000), "2.1M tokens")
    }

    func testBThreshold() {
        XCTAssertEqual(ClaudeCodeHeadlineFormatter.tokens(3_400_000_000), "3.4B tokens")
    }

    func testSingularNoun() {
        // "1 token" vs "2 tokens". Headline always plural — single token is
        // not a realistic Claude Code state worth disambiguating in UI.
        XCTAssertEqual(ClaudeCodeHeadlineFormatter.tokens(1), "1 tokens")
    }
}
