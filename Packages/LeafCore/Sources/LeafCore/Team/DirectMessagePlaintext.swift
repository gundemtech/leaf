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
    /// Track C (UC-4) — structured handoff context (last commit / open
    /// review / status / last thread). Optional + tolerant: old clients
    /// never see the key; a malformed snapshot decodes to nil, never failing
    /// the plaintext (see HandoffContextSnapshot doc).
    public let contextSnapshot: HandoffContextSnapshot?
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
        contextSnapshot: HandoffContextSnapshot? = nil,
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
        self.contextSnapshot = contextSnapshot
        self.replyTo = replyTo
        self.sentAtMs = sentAtMs
    }

    /// Track C — custom decode so the snapshot is per-field tolerant while
    /// every pre-existing field keeps strict semantics (a truly malformed
    /// plaintext must still throw; only snapshot rot degrades silently).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.messageID = try c.decode(String.self, forKey: .messageID)
        self.workspaceID = try c.decode(String.self, forKey: .workspaceID)
        self.senderMemberID = try c.decode(String.self, forKey: .senderMemberID)
        self.senderPubkeyHex = try c.decode(String.self, forKey: .senderPubkeyHex)
        self.senderDisplayName = try c.decode(String.self, forKey: .senderDisplayName)
        self.recipientMemberID = try c.decodeIfPresent(String.self, forKey: .recipientMemberID)
        self.recipientPubkeyHex = try c.decode(String.self, forKey: .recipientPubkeyHex)
        self.kind = try c.decode(DirectMessageKind.self, forKey: .kind)
        self.body = try c.decode(String.self, forKey: .body)
        self.attachment = try c.decodeIfPresent(DirectMessageAttachment.self, forKey: .attachment)
        self.contextSnapshot =
            try? c.decodeIfPresent(HandoffContextSnapshot.self, forKey: .contextSnapshot)
        self.replyTo = try c.decodeIfPresent(String.self, forKey: .replyTo)
        self.sentAtMs = try c.decode(Int64.self, forKey: .sentAtMs)
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
        case contextSnapshot    = "context_snapshot"
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
