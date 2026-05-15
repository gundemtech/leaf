import Foundation

/// Phase Track-5 S5 — JSON-encoded plaintext sealed inside the AES-GCM-256
/// envelope of an auto-shared team event. Encoded under `teamKey` of the
/// owning workspace.
///
/// Wire keys are snake_case to match server-side conventions (Track 5
/// contract §8 + Supabase `team_events` shape). `payload` is the
/// ADR-010-filtered subset built by `TeamEventPayloadBuilder` — banned keys
/// (body, file_contents, note_body, email_subject, preview, prompt, response,
/// *_message_text) never present by construction.
public struct TeamEventPlaintext: Sendable, Equatable, Codable, Hashable {
    public let eventID: String
    public let workspaceID: String
    public let senderMemberID: String
    public let senderPubkeyHex: String
    public let source: ShareSource
    public let kind: String
    public let payload: TeamEventPayload
    public let eventTsMs: Int64

    public init(
        eventID: String,
        workspaceID: String,
        senderMemberID: String,
        senderPubkeyHex: String,
        source: ShareSource,
        kind: String,
        payload: TeamEventPayload,
        eventTsMs: Int64
    ) {
        self.eventID = eventID
        self.workspaceID = workspaceID
        self.senderMemberID = senderMemberID
        self.senderPubkeyHex = senderPubkeyHex
        self.source = source
        self.kind = kind
        self.payload = payload
        self.eventTsMs = eventTsMs
    }

    private enum CodingKeys: String, CodingKey {
        case eventID         = "event_id"
        case workspaceID     = "workspace_id"
        case senderMemberID  = "sender_member_id"
        case senderPubkeyHex = "sender_pubkey_hex"
        case source
        case kind
        case payload
        case eventTsMs       = "event_ts_ms"
    }
}
