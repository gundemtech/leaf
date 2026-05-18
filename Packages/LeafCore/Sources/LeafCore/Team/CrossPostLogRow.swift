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

    // MARK: - CodingKeys (PostgREST snake_case mapping)

    /// Explicit CodingKeys so Codable synthesis maps PostgREST snake_case column
    /// names (message_id, external_ref, etc.) to Swift camelCase properties.
    /// Without this, synthesized keys would look for "messageID", "externalRef",
    /// etc. — causing decode failures on rows returned by `/rest/v1/cross_post_log`.
    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case platform
        case externalRef = "external_ref"
        case externalURL = "external_url"
        case postedAtMs = "posted_at_ms"
        case errorText = "error_text"
    }

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

    // MARK: - Codable (custom decoder enforces HTTPS invariant at decode time)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messageID  = try container.decode(String.self, forKey: .messageID)
        platform   = try container.decode(String.self, forKey: .platform)
        externalRef = try container.decode(String.self, forKey: .externalRef)
        let rawURL  = try container.decode(URL.self, forKey: .externalURL)
        guard rawURL.scheme == "https" else {
            throw DecodingError.dataCorruptedError(
                forKey: .externalURL,
                in: container,
                debugDescription: "externalURL must use https scheme, got: \(rawURL.scheme ?? "nil")"
            )
        }
        externalURL = rawURL
        postedAtMs  = try container.decode(Int64.self, forKey: .postedAtMs)
        errorText   = try container.decodeIfPresent(String.self, forKey: .errorText)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(messageID,  forKey: .messageID)
        try container.encode(platform,   forKey: .platform)
        try container.encode(externalRef, forKey: .externalRef)
        try container.encode(externalURL, forKey: .externalURL)
        try container.encode(postedAtMs,  forKey: .postedAtMs)
        try container.encodeIfPresent(errorText, forKey: .errorText)
    }
}
