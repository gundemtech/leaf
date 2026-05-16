//
//  CrossPostHumanMessageTests.swift
//  LeafCoreTests
//
//  Track 5 / S6 T12 — copy table for status rows in SendDirectMessageSheet.
//
//  Coverage matrix:
//   - Success path with + without channel/identifier metadata.
//   - Known Slack error codes (sentinels + Slack's own returns).
//   - Known Linear error codes.
//   - A14 retry-after fallback ALWAYS takes precedence over generic
//     "rate_limited" code (so even degraded responses without a code
//     surface retry timing).
//   - Unknown error code passes through with provider prefix so failures
//     remain debuggable in UI without leaking response body.
//

import XCTest
@testable import LeafCore

final class CrossPostHumanMessageTests: XCTestCase {

    // MARK: - Slack success

    func testSlackSuccess_WithChannel_ReturnsPostedTo() {
        let result = SlackCrossPostResult(
            ok: true, ts: "1700000000.0001",
            channelID: "C12345", error: nil, retryAfterSeconds: nil
        )
        XCTAssertEqual(
            CrossPostHumanMessage.text(for: result),
            "Posted to Slack channel C12345"
        )
    }

    func testSlackSuccess_NoChannel_FallsBackToGeneric() {
        let result = SlackCrossPostResult(
            ok: true, ts: nil, channelID: nil,
            error: nil, retryAfterSeconds: nil
        )
        XCTAssertEqual(CrossPostHumanMessage.text(for: result), "Posted to Slack")
    }

    // MARK: - Slack failure — sentinels we emit ourselves

    func testSlackError_NotConnected_PointsToSettings() {
        let result = SlackCrossPostResult(
            ok: false, ts: nil, channelID: nil,
            error: "not_connected", retryAfterSeconds: nil
        )
        XCTAssertTrue(
            CrossPostHumanMessage.text(for: result).contains("Settings")
        )
    }

    func testSlackError_InvalidUUID_GenericInternalError() {
        let result = SlackCrossPostResult(
            ok: false, ts: nil, channelID: nil,
            error: "invalid_uuid", retryAfterSeconds: nil
        )
        XCTAssertEqual(
            CrossPostHumanMessage.text(for: result),
            "Slack: internal error. Try again."
        )
    }

    // MARK: - Slack failure — Slack API codes

    func testSlackError_ChannelNotFound() {
        let result = SlackCrossPostResult(
            ok: false, ts: nil, channelID: nil,
            error: "channel_not_found", retryAfterSeconds: nil
        )
        XCTAssertTrue(
            CrossPostHumanMessage.text(for: result).contains("channel not found")
        )
    }

    func testSlackError_InvalidAuth_PromptsReauthorize() {
        let result = SlackCrossPostResult(
            ok: false, ts: nil, channelID: nil,
            error: "invalid_auth", retryAfterSeconds: nil
        )
        XCTAssertTrue(
            CrossPostHumanMessage.text(for: result).contains("Re-authorize")
        )
    }

    func testSlackError_MissingScope_PromptsReauthorize() {
        let result = SlackCrossPostResult(
            ok: false, ts: nil, channelID: nil,
            error: "missing_scope", retryAfterSeconds: nil
        )
        XCTAssertTrue(
            CrossPostHumanMessage.text(for: result).contains("Re-authorize")
        )
    }

    // MARK: - A14 — Slack rate-limit with retry-after takes precedence

    func testSlackError_RateLimited_WithRetryAfter_SurfacesSeconds() {
        let result = SlackCrossPostResult(
            ok: false, ts: nil, channelID: nil,
            error: "rate_limited", retryAfterSeconds: 4
        )
        let copy = CrossPostHumanMessage.text(for: result)
        XCTAssertTrue(copy.contains("retry after 4s"), "got: \(copy)")
    }

    func testSlackError_RateLimited_NoRetryAfter_GenericPhrasing() {
        let result = SlackCrossPostResult(
            ok: false, ts: nil, channelID: nil,
            error: "rate_limited", retryAfterSeconds: nil
        )
        let copy = CrossPostHumanMessage.text(for: result)
        XCTAssertFalse(copy.contains("retry after"))
        XCTAssertTrue(copy.contains("rate-limited"))
    }

    func testSlackError_RetryAfterZero_FallsBackToCodeMapping() {
        // A14 only honours positive retry-after — zero or negative should not
        // surface "retry after 0s" since that reads weirdly.
        let result = SlackCrossPostResult(
            ok: false, ts: nil, channelID: nil,
            error: "rate_limited", retryAfterSeconds: 0
        )
        let copy = CrossPostHumanMessage.text(for: result)
        XCTAssertFalse(copy.contains("retry after 0"), "got: \(copy)")
    }

    func testSlackError_UnknownCode_PassesThroughWithPrefix() {
        let result = SlackCrossPostResult(
            ok: false, ts: nil, channelID: nil,
            error: "some_new_slack_code", retryAfterSeconds: nil
        )
        XCTAssertEqual(
            CrossPostHumanMessage.text(for: result),
            "Slack: some_new_slack_code"
        )
    }

    func testSlackError_EmptyCode_GenericFallback() {
        let result = SlackCrossPostResult(
            ok: false, ts: nil, channelID: nil,
            error: "", retryAfterSeconds: nil
        )
        XCTAssertEqual(
            CrossPostHumanMessage.text(for: result),
            "Slack: couldn't post"
        )
    }

    // MARK: - Linear success

    func testLinearSuccess_WithIdentifier_PostedToIdent() {
        let result = LinearCrossPostResult(
            ok: true, issueID: "ISSUE-uuid",
            identifier: "LEA-42",
            url: "https://linear.app/leaf/issue/LEA-42",
            error: nil
        )
        XCTAssertEqual(
            CrossPostHumanMessage.text(for: result),
            "Posted to LEA-42"
        )
    }

    func testLinearSuccess_NoIdentifier_FallsBackToGeneric() {
        let result = LinearCrossPostResult(
            ok: true, issueID: nil, identifier: nil, url: nil, error: nil
        )
        XCTAssertEqual(CrossPostHumanMessage.text(for: result), "Posted to Linear")
    }

    // MARK: - Linear failure

    func testLinearError_NotConnected_PointsToSettings() {
        let result = LinearCrossPostResult(
            ok: false, issueID: nil, identifier: nil, url: nil,
            error: "not_connected"
        )
        XCTAssertTrue(
            CrossPostHumanMessage.text(for: result).contains("Settings")
        )
    }

    func testLinearError_AuthenticationError_PromptsReauthorize() {
        let result = LinearCrossPostResult(
            ok: false, issueID: nil, identifier: nil, url: nil,
            error: "authentication_error"
        )
        XCTAssertTrue(
            CrossPostHumanMessage.text(for: result).contains("Re-authorize")
        )
    }

    func testLinearError_Ratelimited_FriendlyCopy() {
        let result = LinearCrossPostResult(
            ok: false, issueID: nil, identifier: nil, url: nil,
            error: "ratelimited"
        )
        XCTAssertTrue(
            CrossPostHumanMessage.text(for: result).contains("rate-limited")
        )
    }

    func testLinearError_LinearAPIError_GenericRetryCopy() {
        let result = LinearCrossPostResult(
            ok: false, issueID: nil, identifier: nil, url: nil,
            error: "linear_api_error"
        )
        XCTAssertTrue(
            CrossPostHumanMessage.text(for: result).contains("API error")
        )
    }

    func testLinearError_UnknownCode_PassesThroughWithPrefix() {
        let result = LinearCrossPostResult(
            ok: false, issueID: nil, identifier: nil, url: nil,
            error: "some_new_linear_code"
        )
        XCTAssertEqual(
            CrossPostHumanMessage.text(for: result),
            "Linear: some_new_linear_code"
        )
    }
}
