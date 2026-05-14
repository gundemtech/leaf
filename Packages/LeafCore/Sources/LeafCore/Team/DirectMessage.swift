import Foundation

/// Phase Track-5 S4 — local read model for a row in `messages_mirror`.
///
/// Plain Sendable struct (no GRDB Record protocol) — CRUD via `MessagesMirrorStore`
/// mirroring the `PendingInvitesStore` / `PresenceStateWriter` pattern.
public struct DirectMessageMirrorRow: Sendable, Equatable {
    public let messageID: String
    public let workspaceID: String
    public let senderPubkeyHex: String
    public let senderMemberID: String
    public let senderDisplayName: String
    public let recipientPubkeyHex: String
    public let kind: DirectMessageKind
    public let body: String
    public let attachment: DirectMessageAttachment?
    public let replyTo: String?
    public let sentAtMs: Int64
    public let serverCreatedAtMs: Int64
    public let readAtMs: Int64?
    public let doneAtMs: Int64?
    public let doneByPubkeyHex: String?
    public let direction: Direction
    public let lastSyncedAtMs: Int64

    public enum Direction: String, Sendable, Equatable {
        case outbound
        case inbound

        public var rawValue: String {
            switch self {
            case .outbound: return Schema.MessagesMirror.directionOutbound
            case .inbound:  return Schema.MessagesMirror.directionInbound
            }
        }

        public init?(rawValue: String) {
            switch rawValue {
            case Schema.MessagesMirror.directionOutbound: self = .outbound
            case Schema.MessagesMirror.directionInbound:  self = .inbound
            default: return nil
            }
        }
    }

    public init(
        messageID: String,
        workspaceID: String,
        senderPubkeyHex: String,
        senderMemberID: String,
        senderDisplayName: String,
        recipientPubkeyHex: String,
        kind: DirectMessageKind,
        body: String,
        attachment: DirectMessageAttachment? = nil,
        replyTo: String? = nil,
        sentAtMs: Int64,
        serverCreatedAtMs: Int64,
        readAtMs: Int64? = nil,
        doneAtMs: Int64? = nil,
        doneByPubkeyHex: String? = nil,
        direction: Direction,
        lastSyncedAtMs: Int64
    ) {
        self.messageID = messageID
        self.workspaceID = workspaceID
        self.senderPubkeyHex = senderPubkeyHex
        self.senderMemberID = senderMemberID
        self.senderDisplayName = senderDisplayName
        self.recipientPubkeyHex = recipientPubkeyHex
        self.kind = kind
        self.body = body
        self.attachment = attachment
        self.replyTo = replyTo
        self.sentAtMs = sentAtMs
        self.serverCreatedAtMs = serverCreatedAtMs
        self.readAtMs = readAtMs
        self.doneAtMs = doneAtMs
        self.doneByPubkeyHex = doneByPubkeyHex
        self.direction = direction
        self.lastSyncedAtMs = lastSyncedAtMs
    }
}
