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
    // Phase 5.3.B (consumers: RotationBlobHeader.peek + ProdRotationBlobCodec).
    // Surfaced on short-bytes / version mismatch / AES-GCM tag fail / JSON decode failure /
    // cross-field invariant violation between kind and other RotationPlaintext fields.
    case rotationBlobMalformed
    // Phase 5.3.C (consumer: RelayClient rotation methods) — 4xx surfaces from
    // POST /v1/key-rotation, GET /v1/key-rotation/by-peer/, DELETE /v1/key-rotation/.
    case rotationRequestRejected(reason: String)
    // Phase 5.3.D (consumer: KeyRotationService.removeMember preflight) —
    // admin cannot kick themselves out of their own org.
    case cannotRemoveSelfFromTeam
    // Phase 5.5.A (consumers: JoinCode value type + InviteURL value type) —
    // surfaced when callers wrap value-type errors into LeafError.
    case joinCodeMalformed
    case joinCodeChecksumMismatch
    case inviteURLMalformed
    // Phase 5.5.B (consumers: InviteAcceptService remap of inviteNotFound; InviteAcceptReader UX message).
    case inviteAlreadyConsumed
    // Track 5 / S3 (consumer: InviteAcceptService) — resolve.require_otp=true and caller did not provide OTP.
    // UI response: expand OTP input field on AcceptInviteSheet.
    case inviteOTPRequired
    // Track 5 / S3 (consumer: any caller falling back from unknown SupabaseError / other unmapped error).
    case unknown
    // Track 5 / S4 (consumer: DirectMessageBlobCodec + DirectMessageInboxService.tick row decoder).
    // Surfaced on short bytes / unknown version / AES-GCM tag fail / JSON decode failure.
    case directMessageBlobMalformed
    // Track 5 / S4 (consumer: DirectMessageService.send pre-encrypt validation) — body exceeded
    // safety cap (>64KB). Caller surfaces inline UI error before re-enabling Send button.
    case directMessageBodyTooLarge
    // Track 5 / S4 (consumer: APNsRegistrationService) — Supabase apns_tokens UPSERT failed
    // (network / 4xx / 5xx). Local row exists; retry on next launch / scenePhase=active.
    case apnsRegistrationFailed(reason: String)
    // Track 5 / S4 (consumer: SupabaseSessionStore) — disk read/write/parse failure when
    // persisting refresh_token to keystore. Non-fatal — session works in-memory.
    case supabaseSessionStoreFailure(reason: String)
    // Track 5 / S4 (consumer: DirectMessageService.send fire-and-forget APNs trigger) —
    // apns_push Edge Function returned non-200. Message persists regardless;
    // SentDirectMessage.pushDispatchStatus carries the reason.
    case apnsPushDispatchFailed(reason: String)
}
