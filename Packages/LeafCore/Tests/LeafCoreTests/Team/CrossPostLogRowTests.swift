//
//  CrossPostLogRowTests.swift
//  LeafCoreTests
//
//  Track 5 / S7 B.7 — HTTPS-only URL invariant for CrossPostLogRow.
//

import XCTest
@testable import LeafCore

final class CrossPostLogRowTests: XCTestCase {

    private let httpsURL = URL(string: "https://linear.app/workspace/issue/LEA-123")!
    private let httpURL  = URL(string: "http://example.com")!

    // MARK: - Happy path

    func testValidHTTPSURL_NilError_Succeeds() throws {
        let row = try CrossPostLogRow(
            messageID: "msg-1",
            platform: "linear",
            externalRef: "LEA-123",
            externalURL: httpsURL,
            postedAtMs: 1_716_900_000_000,
            errorText: nil
        )
        XCTAssertEqual(row.messageID, "msg-1")
        XCTAssertEqual(row.platform, "linear")
        XCTAssertEqual(row.externalRef, "LEA-123")
        XCTAssertEqual(row.externalURL, httpsURL)
        XCTAssertEqual(row.postedAtMs, 1_716_900_000_000)
        XCTAssertNil(row.errorText)
    }

    func testValidHTTPSURL_WithError_Succeeds() throws {
        let row = try CrossPostLogRow(
            messageID: "msg-2",
            platform: "slack",
            externalRef: "#leaf-architecture",
            externalURL: httpsURL,
            postedAtMs: 0,
            errorText: "rate_limited"
        )
        XCTAssertEqual(row.errorText, "rate_limited")
    }

    // MARK: - HTTPS-only invariant

    func testNonHTTPSURL_Throws() {
        XCTAssertThrowsError(
            try CrossPostLogRow(
                messageID: "m1",
                platform: "slack",
                externalRef: "#test",
                externalURL: httpURL,
                postedAtMs: 0,
                errorText: nil
            )
        ) { error in
            XCTAssertEqual(error as? CrossPostLogRow.Error, .nonHTTPSURL)
        }
    }

    func testHTTPURL_ThrowsNonHTTPSURL() {
        // Regression guard: plain http must be rejected even on port 443.
        let weirdHTTP = URL(string: "http://slack.com:443/channel")!
        XCTAssertThrowsError(
            try CrossPostLogRow(
                messageID: "m2",
                platform: "slack",
                externalRef: "#test",
                externalURL: weirdHTTP,
                postedAtMs: 0,
                errorText: nil
            )
        ) { error in
            XCTAssertEqual(error as? CrossPostLogRow.Error, .nonHTTPSURL)
        }
    }

    // MARK: - Identifiable

    func testID_IsComposite() throws {
        let row = try CrossPostLogRow(
            messageID: "m3",
            platform: "slack",
            externalRef: "#general",
            externalURL: httpsURL,
            postedAtMs: 0,
            errorText: nil
        )
        XCTAssertEqual(row.id, "m3-slack-#general")
    }

    // MARK: - Codable round-trip

    func testCodableRoundTrip() throws {
        let original = try CrossPostLogRow(
            messageID: "m4",
            platform: "linear",
            externalRef: "LEA-99",
            externalURL: httpsURL,
            postedAtMs: 999,
            errorText: "timeout"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CrossPostLogRow.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
