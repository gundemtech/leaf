// Phase 4.7.B (B-8) — unit tests for LinearAttachmentParser pure-function namespace.
// Coverage: positive GitHub PR / Slack permalink matches + negative cases.
// ADR-010 invariant: parser работает только над URL string, никакого body /
// title / metadata content не получает (provider их не запрашивает в GraphQL).

import XCTest

@testable import LeafCore

final class LinearAttachmentParserTests: XCTestCase {

    // MARK: - GitHub PR

    func testParseGitHubPR_PositiveBasic() {
        let result = LinearAttachmentParser.parseGitHubPR("https://github.com/octocat/leaf/pull/42")
        XCTAssertEqual(result?.repo, "octocat/leaf")
        XCTAssertEqual(result?.prNumber, 42)
    }

    func testParseGitHubPR_PositiveTrailingSlashAndQuery() {
        // Trailing slash + query string не должны ломать match — pattern не
        // anchor'ится на `$`. Capture groups забирают только до `/pull/<num>`.
        let result = LinearAttachmentParser.parseGitHubPR(
            "https://github.com/gundemtech/leaf/pull/123/files?diff=split"
        )
        XCTAssertEqual(result?.repo, "gundemtech/leaf")
        XCTAssertEqual(result?.prNumber, 123)
    }

    func testParseGitHubPR_NegativeIssuesURL() {
        // Issues URLs не PR'ы — должны быть rejected.
        let result = LinearAttachmentParser.parseGitHubPR("https://github.com/octocat/leaf/issues/42")
        XCTAssertNil(result)
    }

    func testParseGitHubPR_NegativeAPIDomain() {
        // api.github.com URLs (machine-readable) не human-readable PR URL'ы.
        let result = LinearAttachmentParser.parseGitHubPR("https://api.github.com/repos/octocat/leaf/pull/42")
        XCTAssertNil(result)
    }

    func testParseGitHubPR_NegativeMalformed() {
        XCTAssertNil(LinearAttachmentParser.parseGitHubPR(""))
        XCTAssertNil(LinearAttachmentParser.parseGitHubPR("https://github.com/octocat/leaf"))
        XCTAssertNil(LinearAttachmentParser.parseGitHubPR("https://github.com/octocat/leaf/pull/abc"))
        XCTAssertNil(LinearAttachmentParser.parseGitHubPR("not-a-url"))
    }

    // MARK: - Slack permalink

    func testParseSlackPermalink_Positive() {
        // Standard Slack permalink convention: p<seconds><micros> → split after
        // first 10 chars to get `<seconds>.<micros>`.
        let result = LinearAttachmentParser.parseSlackPermalink(
            "https://my-team.slack.com/archives/C01ABCDEF/p1700000000123456"
        )
        XCTAssertEqual(result?.channelID, "C01ABCDEF")
        XCTAssertEqual(result?.ts, "1700000000.123456")
    }

    func testParseSlackPermalink_PositiveDifferentChannelPrefix() {
        // Slack channel IDs могут начинаться с D (DM) / G (group) — pattern allows
        // alphanumeric uppercase. Plus mixed digit/letter combinations.
        let result = LinearAttachmentParser.parseSlackPermalink(
            "https://gundemtech.slack.com/archives/D9876XYZW/p1234567890987654"
        )
        XCTAssertEqual(result?.channelID, "D9876XYZW")
        XCTAssertEqual(result?.ts, "1234567890.987654")
    }

    func testParseSlackPermalink_NegativeMalformed() {
        XCTAssertNil(LinearAttachmentParser.parseSlackPermalink(""))
        XCTAssertNil(
            LinearAttachmentParser.parseSlackPermalink(
                "https://my-team.slack.com/archives/C01ABCDEF"  // нет /p<ts>
            ))
        XCTAssertNil(
            LinearAttachmentParser.parseSlackPermalink(
                "https://my-team.slack.com/archives/c01abcdef/p1234567890"  // lowercase channel
            ))
        // Wrong scheme.
        XCTAssertNil(
            LinearAttachmentParser.parseSlackPermalink(
                "http://my-team.slack.com/archives/C01ABCDEF/p1700000000123456"
            ))
        XCTAssertNil(LinearAttachmentParser.parseSlackPermalink("not-a-url"))
    }

    func testParseSlackPermalink_NegativeNotSlackDomain() {
        // Different domain — даже если path matches.
        XCTAssertNil(
            LinearAttachmentParser.parseSlackPermalink(
                "https://example.com/archives/C01ABCDEF/p1700000000123456"
            ))
    }
}
