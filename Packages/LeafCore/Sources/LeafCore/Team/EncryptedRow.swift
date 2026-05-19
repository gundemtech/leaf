//
//  EncryptedRow.swift
//  LeafCore
//
//  Track 5 / S8 / T0 — Phase H Realtime decryption wiring.
//
//  Compile-time fence for the Realtime decryption pipeline (A-I4 carry-over
//  from S7 Stage 6 review).
//
//  Threat model:
//    The Realtime push path receives a `SupabaseTeamEventRow` /
//    `SupabaseDirectMessageRow` from the websocket. That row carries BOTH:
//      • encrypted-only fields (encrypted_payload bytes)
//      • RLS-attested server fields (workspace_id, sender_pubkey, kind, ...)
//
//    The sender_pubkey column is server-attested (RLS WITH CHECK enforces it
//    matches the JWT pubkey of the inserter), but the kind / reply_to columns
//    are sender-controlled at INSERT time and could be mutated by a compromised
//    relay without invalidating the AES-GCM tag (AAD binds only [version|keyID],
//    NOT server columns — same threat as the C2/C4 fixes from S4/S5/S7).
//
//    The decryptor closure receives ONLY the fields needed for AES-GCM decode.
//    The C2/C3 trust gates compare plaintext.senderPubkeyHex / plaintext.workspaceID
//    against the RLS-attested server columns — those comparisons happen
//    INSIDE `LeafRealtimeService.handleTeamEventInsert` / handleDirectMessageInsert,
//    AFTER the decryptor returns the plaintext. Mirror row construction follows
//    the gate (plaintext-wins for kind/replyTo per S4 C4 precedent).
//
//    By restricting the decryptor signature to `EncryptedTeamEventInput` /
//    `EncryptedDirectMessageInput`, we make it a compile-time impossibility
//    for the decryptor to access the RLS-attested fields before the gates
//    apply. Any future refactor that adds senderPubkeyHex / kind / replyTo to
//    these structs breaks the fence and must be re-reviewed.
//
//  Test: `Packages/LeafCore/Tests/LeafCoreTests/Team/EncryptedRowShapeTests.swift`
//  asserts the shape contract via Mirror reflection.
//
//  Spec: docs/superpowers/specs/2026-05-19-track-5-S8-polish-settings.md
//  §3.2 (architecture diagram) + §6.3 (fence assertion).
//

import Foundation

/// Decryption-only view of a Supabase `team_events` row delivered via Realtime.
///
/// Deliberately omits `senderPubkeyHex`, `kind`, and any other server-controlled
/// column. The decryptor closure receives this shape; C2/C3 trust gates apply
/// AFTER decode in `LeafRealtimeService.handleTeamEventInsert`.
public struct EncryptedTeamEventInput: Sendable {
    /// RLS-attested workspace id — used by the decryptor to scope the
    /// `TeamKeystore.readTeamKey(workspaceID:, keyID:)` lookup.
    public let workspaceID: String

    /// Envelope bytes `[ver:1B=0x04 | keyID:16B | nonce:12B | ct | tag:16B]`.
    /// Body of the AES-GCM-256 envelope sealed by the sender under
    /// the workspace team key identified by `keyID`.
    public let encryptedPayload: Data

    /// 16-byte UUID identifying the team key under which the payload was
    /// sealed. Extracted from envelope bytes 1..17 by the caller; held here
    /// as a Swift `UUID` for type safety.
    public let keyID: UUID

    /// Header prefix bytes `[ver:1B | keyID:16B]` (17B). Bound by the
    /// AES-GCM tag as Additional Authenticated Data. The current codec
    /// implementations reconstruct AAD implicitly from the envelope's leading
    /// bytes, so this field is informational / future-proof — if codec.decode
    /// is ever extended to accept an explicit AAD argument, the caller can
    /// pass `aadHeader` directly without re-shaping the input.
    public let aadHeader: Data

    public init(
        workspaceID: String,
        encryptedPayload: Data,
        keyID: UUID,
        aadHeader: Data
    ) {
        self.workspaceID = workspaceID
        self.encryptedPayload = encryptedPayload
        self.keyID = keyID
        self.aadHeader = aadHeader
    }
}

/// Decryption-only view of a Supabase `direct_messages` row delivered via Realtime.
///
/// Deliberately omits `senderPubkeyHex`, `recipientPubkeyHex`, `kind`, `replyTo`,
/// and any other server-controlled column. The decryptor closure receives this
/// shape; C2/C3 trust gates apply AFTER decode in
/// `LeafRealtimeService.handleDirectMessageInsert`.
///
/// `messageID` is included because it's a PK identifier (RLS-attested via
/// `direct_messages.message_id` PK constraint) and is required to construct the
/// mirror row's identity — harmless from a fence-discipline standpoint.
public struct EncryptedDirectMessageInput: Sendable {
    /// RLS-attested workspace id — scopes the keystore lookup.
    public let workspaceID: String

    /// Server-assigned UUID message id. Used as the PK of the mirror row.
    public let messageID: String

    /// Envelope bytes `[ver:1B=0x03 | keyID:16B | nonce:12B | ct | tag:16B]`.
    public let encryptedPayload: Data

    /// 16-byte UUID identifying the team key under which the payload was sealed.
    public let keyID: UUID

    /// Header prefix `[ver:1B | keyID:16B]` (17B). See `EncryptedTeamEventInput.aadHeader`.
    public let aadHeader: Data

    public init(
        workspaceID: String,
        messageID: String,
        encryptedPayload: Data,
        keyID: UUID,
        aadHeader: Data
    ) {
        self.workspaceID = workspaceID
        self.messageID = messageID
        self.encryptedPayload = encryptedPayload
        self.keyID = keyID
        self.aadHeader = aadHeader
    }
}
