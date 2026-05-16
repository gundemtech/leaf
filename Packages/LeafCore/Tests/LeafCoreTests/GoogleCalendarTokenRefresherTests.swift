// Track-6 P4 Task 10 — GoogleCalendarTokenRefresher tests.
// Proactive refresh (TTL window) + reactive refresh (on 401). `.invalidGrant`
// surfaces as an outcome (not throw) so the caller flips ConnectionState to
// `.reconnectNeeded` per spec §7.5. Other errors propagate.
//
// Stub HTTP impl conforms to `GoogleCalendarOAuthHTTP` and returns a canned
// `Result` — no URLSession / URLProtocol plumbing needed at this layer.

import XCTest
import Foundation
@testable import LeafCore

private struct StubGoogleOAuthHTTP: GoogleCalendarOAuthHTTP {
    let refreshResult: Result<GoogleCalendarAPI.TokenResponse, Error>

    func exchangeCode(
        code: String,
        codeVerifier: String,
        redirectURI: String,
        clientID: String,
        clientSecret: String
    ) async throws -> GoogleCalendarAPI.TokenResponse {
        fatalError("exchangeCode not used in refresher tests")
    }

    func refreshToken(
        refreshToken: String,
        clientID: String,
        clientSecret: String
    ) async throws -> GoogleCalendarAPI.TokenResponse {
        switch refreshResult {
        case .success(let r): return r
        case .failure(let e): throw e
        }
    }
}

private func makeTokenResponse(
    accessToken: String = "ya29.new",
    expiresIn: Int = 3920,
    refreshToken: String? = "1//rotated",
    scope: String? = "https://www.googleapis.com/auth/calendar.readonly",
    tokenType: String? = "Bearer"
) -> GoogleCalendarAPI.TokenResponse {
    // TokenResponse is Codable; construct via JSON to avoid coupling to memberwise init visibility.
    var dict: [String: Any] = [
        "access_token": accessToken,
        "expires_in": expiresIn,
    ]
    if let refreshToken { dict["refresh_token"] = refreshToken }
    if let scope { dict["scope"] = scope }
    if let tokenType { dict["token_type"] = tokenType }
    let data = try! JSONSerialization.data(withJSONObject: dict)
    return try! JSONDecoder().decode(GoogleCalendarAPI.TokenResponse.self, from: data)
}

final class GoogleCalendarTokenRefresherTests: XCTestCase {

    // MARK: - Proactive

    func testProactiveNotDueWhenWindowFarAway() async throws {
        let now: Int64 = 1_700_000_000_000
        let oneHourMs: Int64 = 60 * 60 * 1000
        let stub = StubGoogleOAuthHTTP(refreshResult: .success(makeTokenResponse()))
        let refresher = GoogleCalendarTokenRefresher(
            http: stub,
            clientID: "cid",
            clientSecret: "csec"
        )

        let outcome = try await refresher.refreshIfDueProactive(
            currentAccessToken: "ya29.old",
            currentRefreshToken: "1//rt",
            currentExpiresAtMs: now + oneHourMs,
            nowMs: now
        )

        XCTAssertEqual(outcome, .notDue)
    }

    func testProactiveDueWhenWithinWindow() async throws {
        let now: Int64 = 1_700_000_000_000
        let twoMinMs: Int64 = 2 * 60 * 1000
        let stub = StubGoogleOAuthHTTP(refreshResult: .success(
            makeTokenResponse(accessToken: "ya29.new", expiresIn: 3920, refreshToken: "1//rotated")
        ))
        let refresher = GoogleCalendarTokenRefresher(
            http: stub,
            clientID: "cid",
            clientSecret: "csec"
        )

        let outcome = try await refresher.refreshIfDueProactive(
            currentAccessToken: "ya29.old",
            currentRefreshToken: "1//rt",
            currentExpiresAtMs: now + twoMinMs,
            nowMs: now
        )

        XCTAssertEqual(
            outcome,
            .refreshed(
                accessToken: "ya29.new",
                expiresAtMs: now + Int64(3920) * 1000,
                refreshToken: "1//rotated"
            )
        )
    }

    func testProactiveNotDueWhenExpiresAtMsIsNil() async throws {
        // Defensive: no expiry recorded → assume long-lived; refresh would be wasteful.
        let now: Int64 = 1_700_000_000_000
        let stub = StubGoogleOAuthHTTP(refreshResult: .success(makeTokenResponse()))
        let refresher = GoogleCalendarTokenRefresher(
            http: stub,
            clientID: "cid",
            clientSecret: "csec"
        )

        let outcome = try await refresher.refreshIfDueProactive(
            currentAccessToken: "ya29.old",
            currentRefreshToken: "1//rt",
            currentExpiresAtMs: nil,
            nowMs: now
        )

        XCTAssertEqual(outcome, .notDue)
    }

    // MARK: - Reactive (401)

    func testReactive401SuccessReturnsRefreshed() async throws {
        let now: Int64 = 1_700_000_000_000
        let stub = StubGoogleOAuthHTTP(refreshResult: .success(
            makeTokenResponse(accessToken: "ya29.fresh", expiresIn: 3600, refreshToken: "1//rt-v2")
        ))
        let refresher = GoogleCalendarTokenRefresher(
            http: stub,
            clientID: "cid",
            clientSecret: "csec"
        )

        let outcome = try await refresher.refreshOn401(
            currentRefreshToken: "1//rt",
            nowMs: now
        )

        XCTAssertEqual(
            outcome,
            .refreshed(
                accessToken: "ya29.fresh",
                expiresAtMs: now + 3600 * 1000,
                refreshToken: "1//rt-v2"
            )
        )
    }

    func testReactive401InvalidGrantReturnsInvalidGrant() async throws {
        // Caller — not refresher — transitions ConnectionState → .reconnectNeeded.
        // Refresher must NOT retry, NOT throw — just surface .invalidGrant.
        let stub = StubGoogleOAuthHTTP(refreshResult: .failure(GoogleCalendarOAuthError.invalidGrant))
        let refresher = GoogleCalendarTokenRefresher(
            http: stub,
            clientID: "cid",
            clientSecret: "csec"
        )

        let outcome = try await refresher.refreshOn401(
            currentRefreshToken: "1//revoked",
            nowMs: 1_700_000_000_000
        )

        XCTAssertEqual(outcome, .invalidGrant)
    }

    func testReactive401TransportErrorPropagates() async throws {
        // Transient errors must NOT be swallowed — caller decides retry policy.
        let stub = StubGoogleOAuthHTTP(refreshResult: .failure(
            GoogleCalendarOAuthError.transport("network down")
        ))
        let refresher = GoogleCalendarTokenRefresher(
            http: stub,
            clientID: "cid",
            clientSecret: "csec"
        )

        do {
            _ = try await refresher.refreshOn401(
                currentRefreshToken: "1//rt",
                nowMs: 1_700_000_000_000
            )
            XCTFail("expected transport error to propagate")
        } catch GoogleCalendarOAuthError.transport(let msg) {
            XCTAssertEqual(msg, "network down")
        }
    }

    // MARK: - Refresh response shape

    func testRefreshResponseWithoutRotatedRefreshTokenReturnsNilField() async throws {
        // Google often OMITS refresh_token on refresh; caller preserves prior value.
        // Refresher surfaces `nil` faithfully — does not synthesize a value.
        let now: Int64 = 1_700_000_000_000
        let stub = StubGoogleOAuthHTTP(refreshResult: .success(
            makeTokenResponse(accessToken: "ya29.no-rotate", expiresIn: 3599, refreshToken: nil)
        ))
        let refresher = GoogleCalendarTokenRefresher(
            http: stub,
            clientID: "cid",
            clientSecret: "csec"
        )

        let outcome = try await refresher.refreshOn401(
            currentRefreshToken: "1//rt",
            nowMs: now
        )

        XCTAssertEqual(
            outcome,
            .refreshed(
                accessToken: "ya29.no-rotate",
                expiresAtMs: now + 3599 * 1000,
                refreshToken: nil
            )
        )
    }
}
