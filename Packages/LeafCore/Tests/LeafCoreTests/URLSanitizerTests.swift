// Phase 5 defence-in-depth — browser URL sanitizer tests (audit HIGH H1).
// Exercises AttentionEmissionPlanner.sanitizeURL: always-drop-fragment, host-keyed
// query allowlist, userinfo stripping, and the privacy-safe fallback for unparseable
// input.

import XCTest

@testable import LeafCore

final class URLSanitizerTests: XCTestCase {

    private func sanitize(_ s: String) -> String? { AttentionEmissionPlanner.sanitizeURL(s) }

    // MARK: - Fragment always dropped

    func testDropsOAuthImplicitFragment() {
        XCTAssertEqual(
            sanitize("https://example.com/cb#access_token=SECRET&token_type=bearer"),
            "https://example.com/cb")
    }

    func testDropsJWTFragment() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc123"
        XCTAssertEqual(sanitize("https://example.com/p#id_token=\(jwt)"), "https://example.com/p")
    }

    func testDropsMagicLinkFragment() {
        XCTAssertEqual(
            sanitize("https://auth.example.com/reset#token=reset-secret-xyz"),
            "https://auth.example.com/reset")
    }

    // MARK: - Query allowlist

    func testKeepsGoogleSearchQuery() {
        XCTAssertEqual(
            sanitize("https://www.google.com/search?q=swiftlang&hl=en"),
            "https://www.google.com/search?q=swiftlang")
    }

    func testStripsAllQueryForUnknownHost() {
        XCTAssertEqual(
            sanitize("https://tracker.example.com/p?token=abc&uid=42"),
            "https://tracker.example.com/p")
    }

    func testStripsNonAllowlistedKeyOnAllowlistedHost() {
        // hl stripped, q kept.
        XCTAssertEqual(
            sanitize("https://google.com/search?hl=en&q=hello"),
            "https://google.com/search?q=hello")
    }

    // MARK: - Host matching

    func testHostMatchCaseInsensitive() {
        XCTAssertEqual(sanitize("https://GOOGLE.com/search?q=x"), "https://GOOGLE.com/search?q=x")
    }

    func testSuffixMatchSubdomainUsesParentAllowlist() {
        XCTAssertEqual(
            sanitize("https://news.google.com/search?q=x&foo=1"),
            "https://news.google.com/search?q=x")
    }

    func testLookalikeHostIsNotAllowlisted() {
        // evil-google.com must NOT match google.com → all query stripped.
        XCTAssertEqual(sanitize("https://evil-google.com/p?q=secret"), "https://evil-google.com/p")
    }

    // MARK: - userinfo / scheme / fallback

    func testStripsUserInfoAndPassword() throws {
        let out = try XCTUnwrap(sanitize("https://user:pass@example.com/p"))
        XCTAssertFalse(out.contains("user"))
        XCTAssertFalse(out.contains("pass"))
        XCTAssertTrue(out.contains("example.com"))
    }

    func testNonHTTPSchemeFallbackStripsFragmentAndQuery() {
        XCTAssertEqual(sanitize("myapp://open?token=abc#frag"), "myapp://open")
    }

    func testNoHostFallbackStripsFragment() {
        let out = sanitize("https:///nohost#x")
        XCTAssertNotNil(out)
        XCTAssertFalse(out!.contains("#"))
    }

    func testMalformedUnparseableStillStripsFragment() throws {
        let out = try XCTUnwrap(sanitize("not a real url #access_token=SECRET"))
        XCTAssertFalse(out.contains("#"))
        XCTAssertFalse(out.contains("access_token"))
    }

    // MARK: - truncation / empty

    func testTruncatesToMaxLength() throws {
        let long = "https://example.com/" + String(repeating: "a", count: 5000)
        let out = try XCTUnwrap(sanitize(long))
        XCTAssertLessThanOrEqual(out.count, AttentionEmissionPlanner.urlMaxLength)
    }

    func testEmptyAfterTrimReturnsNil() {
        XCTAssertNil(sanitize("   "))
        XCTAssertNil(sanitize(""))
    }
}
