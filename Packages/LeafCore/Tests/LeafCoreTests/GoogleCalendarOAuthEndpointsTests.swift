import XCTest

@testable import LeafCore

// swiftlint:disable force_unwrapping
// Reason: test fixtures rely on force-unwrap for setup convenience —
// URL literals, HTTPURLResponse construction, decoded JSON, post-`try`
// DB reads where nil ⇒ broken test, not production semantic.

final class GoogleCalendarOAuthEndpointsTests: XCTestCase {
    func testTokenURLIsCorrect() {
        XCTAssertEqual(
            GoogleCalendarOAuthEndpoints.tokenURL.absoluteString,
            "https://oauth2.googleapis.com/token"
        )
    }

    func testScopeIsCalendarReadonly() {
        XCTAssertEqual(
            GoogleCalendarOAuthEndpoints.scope,
            "https://www.googleapis.com/auth/calendar.readonly"
        )
    }

    func testAuthorizeURLContainsAllRequiredParams() {
        let url = GoogleCalendarOAuthEndpoints.authorizeURL(
            clientID: "test-client-id.apps.googleusercontent.com",
            challenge: "CHAL-abc123",
            state: "STATE-xyz789",
            port: 47825
        )
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "accounts.google.com")
        XCTAssertEqual(components.path, "/o/oauth2/v2/auth")

        let params = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
        XCTAssertEqual(params["client_id"], "test-client-id.apps.googleusercontent.com")
        XCTAssertEqual(params["redirect_uri"], "http://127.0.0.1:47825/callback")
        XCTAssertEqual(params["response_type"], "code")
        XCTAssertEqual(params["scope"], "https://www.googleapis.com/auth/calendar.readonly")
        XCTAssertEqual(params["access_type"], "offline")
        XCTAssertEqual(params["prompt"], "consent")
        XCTAssertEqual(params["code_challenge"], "CHAL-abc123")
        XCTAssertEqual(params["code_challenge_method"], "S256")
        XCTAssertEqual(params["state"], "STATE-xyz789")
        XCTAssertEqual(params["include_granted_scopes"], "true")
    }

    func testInfoPlistKeyConstantsMatchExpected() {
        XCTAssertEqual(GoogleCalendarOAuthEndpoints.infoPlistClientIDKey, "LeafGoogleCalendarOAuthClientID")
        XCTAssertEqual(GoogleCalendarOAuthEndpoints.infoPlistClientSecretKey, "LeafGoogleCalendarOAuthClientSecret")
    }
}
// swiftlint:enable force_unwrapping
