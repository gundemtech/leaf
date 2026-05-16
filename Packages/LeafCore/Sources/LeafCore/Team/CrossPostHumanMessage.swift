//
//  CrossPostHumanMessage.swift
//  LeafCore
//
//  Track 5 / S6 T12 — user-facing copy mapping for cross-post results.
//
//  Lives in LeafCore (not the app target) so the same translation table
//  can be unit-tested via SwiftPM without dragging the whole UI in. UI
//  consumes via `CrossPostHumanMessage.text(for: SlackCrossPostResult)` /
//  `text(for: LinearCrossPostResult)` from SendDirectMessageSheet's
//  status row renderer.
//
//  Inputs:
//   - SlackCrossPostResult — `error` is Slack API code ("channel_not_found",
//     "rate_limited", "invalid_auth", …) OR our own marker ("not_connected",
//     "invalid_uuid"). `retryAfterSeconds` is populated when Slack 429
//     returned Retry-After (A14).
//   - LinearCrossPostResult — `error` is Linear GraphQL error code
//     ("authentication_error", "ratelimited", "linear_api_error") OR
//     our marker ("not_connected", "invalid_uuid").
//
//  Output: short, user-grade English copy. Slack error codes are mapped
//  to recognisable phrases; A14 case surfaces "retry after Ns" when
//  retry_after_seconds is non-nil. Unknown codes pass through wrapped
//  ("Slack: <code>") to keep failures debuggable without revealing
//  full HTTP status / response body.
//
//  ADR-010 / privacy: we surface metadata (error code, channel id, issue
//  identifier) only. Slack response body / Linear GraphQL errors[].message
//  are NOT propagated through this layer — Edge Functions strip them at
//  the boundary so the Mac never sees them.
//

import Foundation

public enum CrossPostHumanMessage {

    // MARK: - Slack

    /// User-facing copy for a `SlackCrossPostResult`. Success path returns a
    /// "Posted to #<channel>" line; failure path returns "Slack: <reason>".
    public static func text(for result: SlackCrossPostResult) -> String {
        if result.ok {
            if let channelID = result.channelID, !channelID.isEmpty {
                return "Posted to Slack channel \(channelID)"
            }
            return "Posted to Slack"
        }
        // A14 — surface retry-after seconds when Slack 429 set the header.
        if let retry = result.retryAfterSeconds, retry > 0 {
            return "Slack: rate-limited, retry after \(retry)s"
        }
        guard let code = result.error, !code.isEmpty else {
            return "Slack: couldn't post"
        }
        switch code {
        case "not_connected":
            return "Slack: not connected. Reconnect in Settings → Connections."
        case "invalid_uuid":
            return "Slack: internal error. Try again."
        case "channel_not_found":
            return "Slack: channel not found. Pick a different channel."
        case "not_in_channel":
            return "Slack: bot isn't a member of this channel."
        case "rate_limited":
            return "Slack: rate-limited. Try again shortly."
        case "invalid_auth", "token_revoked", "account_inactive":
            return "Slack: authentication failed. Re-authorize in Settings."
        case "missing_scope":
            return "Slack: missing chat:write scope. Re-authorize."
        case "message_too_long":
            return "Slack: message too long for this channel."
        case "msg_too_long":
            return "Slack: message too long."
        default:
            return "Slack: \(code)"
        }
    }

    // MARK: - Linear

    /// User-facing copy for a `LinearCrossPostResult`. Success path returns
    /// "Posted to LEA-42" using `identifier`; failure path returns
    /// "Linear: <reason>".
    public static func text(for result: LinearCrossPostResult) -> String {
        if result.ok {
            if let identifier = result.identifier, !identifier.isEmpty {
                return "Posted to \(identifier)"
            }
            return "Posted to Linear"
        }
        guard let code = result.error, !code.isEmpty else {
            return "Linear: couldn't create issue"
        }
        switch code {
        case "not_connected":
            return "Linear: not connected. Reconnect in Settings → Connections."
        case "invalid_uuid":
            return "Linear: internal error. Try again."
        case "authentication_error":
            return "Linear: authentication failed. Re-authorize in Settings."
        case "ratelimited", "rate_limited":
            return "Linear: rate-limited. Try again shortly."
        case "linear_api_error":
            return "Linear: API error. Try again."
        case "invalid_team":
            return "Linear: team not found. Pick a different team."
        case "validation_error":
            return "Linear: validation failed."
        default:
            return "Linear: \(code)"
        }
    }
}
