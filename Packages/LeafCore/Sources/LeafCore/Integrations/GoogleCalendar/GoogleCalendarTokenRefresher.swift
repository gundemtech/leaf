//
//  GoogleCalendarTokenRefresher.swift
//  LeafCore
//
//  Track-6 P4 Task 10 — proactive + reactive refresh wrapper around
//  `GoogleCalendarOAuthHTTP`. Spec §7.5.
//
//  Two policies:
//    1. Proactive (`refreshIfDueProactive`) — call before each tick. Refreshes
//       when `expires_at_ms < now + proactiveWindowMs`, otherwise `.notDue`.
//       Avoids 401 cascade mid-tick.
//    2. Reactive (`refreshOn401`) — call on 401 from a downstream Calendar API
//       call. One-shot refresh (no internal retry loop — caller decides).
//
//  `invalid_grant` does NOT throw — surfaces as `.invalidGrant` outcome so
//  the caller flips ConnectionState → `.reconnectNeeded` (spec §7.5). Any
//  other error from the HTTP client propagates unchanged (transport, decode,
//  http(...)) so the caller can distinguish transient vs. fatal.
//
//  Google refresh quirks:
//    • `refresh_token` may be OMITTED on refresh — only rotated occasionally.
//      The outcome surfaces `refreshToken: nil` faithfully; the caller is
//      responsible for preserving the prior value.
//    • Token endpoint speaks form-urlencoded; that's the OAuth client's
//      concern, not this wrapper's.
//

import Foundation

public struct GoogleCalendarTokenRefresher: Sendable {

    /// Outcome of a refresh attempt. `.invalidGrant` is surfaced rather than
    /// thrown so the caller can deterministically transition ConnectionState.
    public enum RefreshOutcome: Sendable, Equatable {
        /// Token endpoint returned 200. `refreshToken` may be `nil` if Google
        /// did not rotate the refresh token on this call (caller preserves prior).
        case refreshed(accessToken: String, expiresAtMs: Int64, refreshToken: String?)

        /// Proactive path only — TTL is still further out than `proactiveWindowMs`,
        /// or no expiry is recorded (long-lived assumption).
        case notDue

        /// Token endpoint returned `invalid_grant` (revoked / scope-changed /
        /// 7-day testing-mode expiry). Caller transitions ConnectionState to
        /// `.reconnectNeeded` per spec §7.5.
        case invalidGrant
    }

    private let http: GoogleCalendarOAuthHTTP
    private let clientID: String
    private let clientSecret: String

    /// Refresh-ahead window in milliseconds. Default 5 min — small relative to
    /// Google's 1h access-token TTL but enough to absorb tick-scheduling jitter.
    private let proactiveWindowMs: Int64

    public init(
        http: GoogleCalendarOAuthHTTP,
        clientID: String,
        clientSecret: String,
        proactiveWindowMs: Int64 = 5 * 60 * 1000
    ) {
        self.http = http
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.proactiveWindowMs = proactiveWindowMs
    }

    /// Proactive refresh — call before each polling tick. Returns `.notDue`
    /// when more than `proactiveWindowMs` of TTL remains, `.refreshed(...)`
    /// when a refresh succeeded, `.invalidGrant` when the refresh token was
    /// rejected. Transport / decode / http errors propagate.
    public func refreshIfDueProactive(
        currentAccessToken: String,
        currentRefreshToken: String,
        currentExpiresAtMs: Int64?,
        nowMs: Int64
    ) async throws -> RefreshOutcome {
        // No expiry recorded → assume long-lived (legacy / testing). Refreshing
        // would either burn a refresh token rotation slot or worse, return
        // invalid_grant if the upstream stored value was actually expired
        // long ago. Safer to defer to the reactive path.
        guard let expiresAtMs = currentExpiresAtMs else {
            return .notDue
        }
        guard expiresAtMs < nowMs + proactiveWindowMs else {
            return .notDue
        }
        return try await performRefresh(refreshToken: currentRefreshToken, nowMs: nowMs)
    }

    /// Reactive refresh — call once on 401 from a downstream Calendar API call.
    /// No internal retry loop: caller wraps the actual API call + outcome
    /// handling (retry, surface to UI, etc.). Outcomes mirror the proactive
    /// path minus `.notDue` (a 401 is itself the "due" signal).
    public func refreshOn401(
        currentRefreshToken: String,
        nowMs: Int64
    ) async throws -> RefreshOutcome {
        try await performRefresh(refreshToken: currentRefreshToken, nowMs: nowMs)
    }

    // MARK: - Private

    private func performRefresh(refreshToken: String, nowMs: Int64) async throws -> RefreshOutcome {
        do {
            let response = try await http.refreshToken(
                refreshToken: refreshToken,
                clientID: clientID,
                clientSecret: clientSecret
            )
            // Compute absolute expiry against caller's `nowMs` so tests can
            // assert exact values and the production caller can persist a
            // value comparable against subsequent `Date().millisecondsSince1970`.
            let expiresAtMs = nowMs + Int64(response.expiresIn) * 1000
            return .refreshed(
                accessToken: response.accessToken,
                expiresAtMs: expiresAtMs,
                refreshToken: response.refreshToken  // nil-tolerant — caller preserves prior on nil.
            )
        } catch GoogleCalendarOAuthError.invalidGrant {
            return .invalidGrant
        }
        // Other GoogleCalendarOAuthError cases (http / decoding / transport /
        // missingResponseField) propagate — caller decides retry vs. surface.
    }
}
