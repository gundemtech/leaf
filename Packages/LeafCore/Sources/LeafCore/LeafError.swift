import Foundation

public enum LeafError: Error, Sendable {
    case notImplemented
    case databaseUnavailable
    case keychainUnavailable(OSStatus)
    case keyFileUnavailable(reason: String)
    case keyFileCorrupted
    case corruptedEnvelope
    case invalidPayload
    case jsonEncodingFailed
    case orgAlreadyExists
    case inviteBlobMalformed
    case inviteOTPInvalid
    // Phase 5.2.D additions (consumers: RelayClient HTTP layer + InviteService).
    case relayUnreachable(reason: String)
    case inviteNotFound
    case inviteRequestRejected(reason: String)
    // Phase 5.2.E (consumer: InviteAcceptService) — single-org-per-device invariant
    // means accept-flow refuses if local DB already has an org row.
    case inviteAlreadyAccepted
}
