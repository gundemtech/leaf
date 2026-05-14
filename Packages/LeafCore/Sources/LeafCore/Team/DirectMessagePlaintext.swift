import Foundation

/// Phase Track-5 S4 — JSON-encoded plaintext sealed inside the
/// AES-GCM-256 envelope of a direct message. Encoded under `teamKey` of the
/// owning workspace.
///
/// Wire keys are snake_case to match server-side conventions (see Track 5
/// contract §8 + Supabase `direct_messages` shape).
public struct DirectMessagePlaintext: Sendable, Equatable, Codable, Hashable {
    public let messageID: String
    public let workspaceID: String
    public let senderMemberID: String
    public let senderPubkeyHex: String
    public let senderDisplayName: String
    public let recipientMemberID: String?
    public let recipientPubkeyHex: String
    public let kind: DirectMessageKind
    public let body: String
    public let attachment: DirectMessageAttachment?
    public let replyTo: String?
    public let sentAtMs: Int64

    public init(
        messageID: String,
        workspaceID: String,
        senderMemberID: String,
        senderPubkeyHex: String,
        senderDisplayName: String,
        recipientMemberID: String?,
        recipientPubkeyHex: String,
        kind: DirectMessageKind,
        body: String,
        attachment: DirectMessageAttachment?,
        replyTo: String?,
        sentAtMs: Int64
    ) {
        self.messageID = messageID
        self.workspaceID = workspaceID
        self.senderMemberID = senderMemberID
        self.senderPubkeyHex = senderPubkeyHex
        self.senderDisplayName = senderDisplayName
        self.recipientMemberID = recipientMemberID
        self.recipientPubkeyHex = recipientPubkeyHex
        self.kind = kind
        self.body = body
        self.attachment = attachment
        self.replyTo = replyTo
        self.sentAtMs = sentAtMs
    }

    private enum CodingKeys: String, CodingKey {
        case messageID          = "message_id"
        case workspaceID        = "workspace_id"
        case senderMemberID     = "sender_member_id"
        case senderPubkeyHex    = "sender_pubkey_hex"
        case senderDisplayName  = "sender_display_name"
        case recipientMemberID  = "recipient_member_id"
        case recipientPubkeyHex = "recipient_pubkey_hex"
        case kind
        case body
        case attachment
        case replyTo            = "reply_to"
        case sentAtMs           = "sent_at_ms"
    }
}

/// Phase Track-5 S4 — optional event reference attached to a direct message.
/// Carries minimal external_ref (e.g. "PR #142", "LEAF-128") — never the full
/// event body. Populated post-S5 (S4 always nil — see spec §3 out-of-scope).
public struct DirectMessageAttachment: Sendable, Equatable, Codable, Hashable {
    public let kind: String
    public let externalRef: String
    public let displayLabel: String?

    public init(kind: String, externalRef: String, displayLabel: String?) {
        self.kind = kind
        self.externalRef = externalRef
        self.displayLabel = displayLabel
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case externalRef  = "external_ref"
        case displayLabel = "display_label"
    }
}
