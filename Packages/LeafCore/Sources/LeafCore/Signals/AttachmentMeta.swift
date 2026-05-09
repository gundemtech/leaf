import Foundation

/// Phase Track-1 D1 — shared attachment metadata across Linear / GitHub / Slack.
/// Captures filename + mime + size; NEVER content (ADR-010 §6 amendment — bodies
/// allowed on-device but file contents remain forbidden everywhere).
///
/// Encoded as JSON array of these objects under payload key `attachments_json`.
/// Empty array → key omitted (consistent with existing collector convention).
public struct AttachmentMeta: Codable, Sendable, Hashable {
    /// Filename as authored by the user / surfaced by the provider.
    public let name: String
    /// IANA MIME type. `nil` if neither the provider nor extension-based inference
    /// supplied a value (e.g. inline image URLs where the loader may attempt
    /// extension inference, but no fallback is required).
    public let mime: String?
    /// File size in bytes. `nil` if unknown (e.g. inline image URLs without HEAD fetch).
    public let sizeBytes: Int?

    enum CodingKeys: String, CodingKey {
        case name
        case mime
        case sizeBytes = "size_bytes"
    }

    public init(name: String, mime: String? = nil, sizeBytes: Int? = nil) {
        self.name = name
        self.mime = mime
        self.sizeBytes = sizeBytes
    }
}
