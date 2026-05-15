import Foundation

/// Phase Track-5 S5 — ADR-010-filtered payload sealed inside the AES-GCM-256
/// envelope of a team event. `fields` is a string-keyed bag with per-source
/// allow-listed keys + per-key truncation caps applied by
/// `TeamEventPayloadBuilder` (the **only** code path that may construct values
/// here in production).
///
/// **Banned keys** (regression-tested in `RelayBodyLeakageTests`):
///   - body, file_contents, note_body, email_subject, preview, prompt,
///     response, slack_message_text, linear_comment_body,
///     github_comment_body, slack_canvas_content
///
/// Allowed keys per source — see `TeamEventPayloadBuilder.allowedKeys(for:)`
/// docstring (single source of truth).
public struct TeamEventPayload: Sendable, Equatable, Codable, Hashable {
    public let fields: [String: String]

    public init(fields: [String: String]) {
        self.fields = fields
    }

    private enum CodingKeys: String, CodingKey {
        case fields
    }
}
