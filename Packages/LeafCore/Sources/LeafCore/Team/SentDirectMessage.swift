import Foundation

/// Phase Track-5 S4 — `DirectMessageService.send` return value.
///
/// `messageID` matches both Supabase `direct_messages.message_id` and the
/// local `messages_mirror` PK that the service inserted for the outbound row.
/// `createdAtISO` is the server-canonical timestamp (used for inbox cursor /
/// retrospective fetch).
///
/// `pushDispatchStatus` reports the best-effort APNs trigger outcome — the
/// message itself persists regardless, so `failed(_)` does NOT throw.
public struct SentDirectMessage: Sendable, Equatable {
    public let messageID: String
    public let createdAtISO: String
    public let pushDispatchStatus: PushDispatchStatus

    public init(messageID: String, createdAtISO: String, pushDispatchStatus: PushDispatchStatus) {
        self.messageID = messageID
        self.createdAtISO = createdAtISO
        self.pushDispatchStatus = pushDispatchStatus
    }

    public enum PushDispatchStatus: Sendable, Equatable {
        case sent
        case skipped
        case failed(String)
    }
}
