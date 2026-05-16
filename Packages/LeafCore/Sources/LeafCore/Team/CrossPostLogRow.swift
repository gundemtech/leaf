//
//  CrossPostLogRow.swift
//  LeafCore
//
//  Track 5 / S7 B.7 — UI projection of a cross_post_log row fetched from
//  Supabase. Used by CrossPostLogReader (Phase C.7) and LeafMessageCard (B.8)
//  to render per-channel status chips beneath a DM body.
//
//  HTTPS-only invariant: externalURL must have scheme == "https" — enforced
//  at init time so callers cannot accidentally surface http:// links.
//

import Foundation

/// A single row from cross_post_log, ready for display in the UI.
public struct CrossPostLogRow: Codable, Hashable, Sendable, Identifiable {

    // MARK: - Error

    public enum Error: Swift.Error, Equatable {
        /// Thrown when `externalURL` is not HTTPS.
        case nonHTTPSURL
    }

    // MARK: - Properties

    /// Matches `direct_messages.id` that triggered this cross-post.
    public let messageID: String

    /// Provider name — "slack" | "linear".
    public let platform: String

    /// Human-readable reference: Slack channel name (e.g., "#leaf-architecture")
    /// or Linear issue key (e.g., "LEA-123").
    public let externalRef: String

    /// Deep-link to the created artefact on the provider. Always HTTPS.
    public let externalURL: URL

    /// Unix epoch milliseconds when the cross-post was recorded.
    public let postedAtMs: Int64

    /// Non-nil when the cross-post failed; contains a short error code
    /// (e.g., "rate_limited", "timeout"). Nil means success.
    public let errorText: String?

    // MARK: - Identifiable

    /// Composite key: ensures uniqueness when the same message is cross-posted
    /// to multiple channels/issues on the same platform.
    public var id: String { "\(messageID)-\(platform)-\(externalRef)" }

    // MARK: - Init

    /// Failable init: throws `.nonHTTPSURL` if `externalURL.scheme != "https"`.
    public init(
        messageID: String,
        platform: String,
        externalRef: String,
        externalURL: URL,
        postedAtMs: Int64,
        errorText: String?
    ) throws {
        guard externalURL.scheme == "https" else { throw Error.nonHTTPSURL }
        self.messageID = messageID
        self.platform = platform
        self.externalRef = externalRef
        self.externalURL = externalURL
        self.postedAtMs = postedAtMs
        self.errorText = errorText
    }
}
