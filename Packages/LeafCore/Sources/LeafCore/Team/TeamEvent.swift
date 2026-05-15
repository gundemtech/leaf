import Foundation

/// Phase Track-5 S5 — local read model for a row in `team_events_mirror`.
///
/// Plain Sendable struct (no GRDB Record protocol). CRUD via
/// `TeamEventMirrorStore` mirroring the `MessagesMirrorStore` pattern.
public struct TeamEventMirrorRow: Sendable, Equatable {
    public let eventID: String
    public let workspaceID: String
    public let senderPubkeyHex: String
    public let source: ShareSource
    public let kind: String
    public let plaintextPayloadJSON: String
    public let serverCreatedAtMs: Int64
    public let eventTsMs: Int64
    public let receivedAtMs: Int64

    public init(
        eventID: String,
        workspaceID: String,
        senderPubkeyHex: String,
        source: ShareSource,
        kind: String,
        plaintextPayloadJSON: String,
        serverCreatedAtMs: Int64,
        eventTsMs: Int64,
        receivedAtMs: Int64
    ) {
        self.eventID = eventID
        self.workspaceID = workspaceID
        self.senderPubkeyHex = senderPubkeyHex
        self.source = source
        self.kind = kind
        self.plaintextPayloadJSON = plaintextPayloadJSON
        self.serverCreatedAtMs = serverCreatedAtMs
        self.eventTsMs = eventTsMs
        self.receivedAtMs = receivedAtMs
    }
}

/// Phase Track-5 S5 — local read model for a row in `team_event_broadcast_offsets`.
public struct TeamEventBroadcastOffset: Sendable, Equatable {
    public let workspaceID: String
    public let cursorEventID: Int64
    public let lastAttemptAtMs: Int64?
    public let lastSuccessAtMs: Int64?
    public let consecutiveFailures: Int

    public init(
        workspaceID: String,
        cursorEventID: Int64,
        lastAttemptAtMs: Int64?,
        lastSuccessAtMs: Int64?,
        consecutiveFailures: Int
    ) {
        self.workspaceID = workspaceID
        self.cursorEventID = cursorEventID
        self.lastAttemptAtMs = lastAttemptAtMs
        self.lastSuccessAtMs = lastSuccessAtMs
        self.consecutiveFailures = consecutiveFailures
    }
}
