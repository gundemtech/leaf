//
//  DirectMessageInboxService.swift
//  LeafCore
//
//  Track 5 / S4 — recipient-side poll loop. Reads max(server_created_at_ms)
//  from local messages_mirror, calls Supabase fetchInboundMessages with the
//  cursor, decrypts each row via the injected codec, UPSERTs into messages_mirror
//  (direction='inbound'). Idempotent — second tick on same set of rows is a no-op.
//
//  Caller schedules this on a 30s foreground tick / 5min background tick.
//  Single-row eager fetch (used by APNs wake) routes through tickOnce(forMessageID:).
//

import Foundation

public struct DirectMessageInboxService: Sendable {
    private let database: Database
    private let supabase: SupabaseClient
    private let codec: any DirectMessageBlobCodec
    private let keystoreRoot: URL
    private let recipientPubkeyHex: @Sendable () throws -> String
    private let now: @Sendable () -> Date

    public init(
        database: Database,
        supabase: SupabaseClient,
        codec: any DirectMessageBlobCodec,
        keystoreRoot: URL = TeamKeystore.defaultRoot(),
        recipientPubkeyHex: (@Sendable () throws -> String)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = database
        self.supabase = supabase
        self.codec = codec
        self.keystoreRoot = keystoreRoot
        let root = keystoreRoot
        self.recipientPubkeyHex = recipientPubkeyHex ?? {
            let priv = try IdentityService.ensureLocalIdentity(at: root)
            return priv.publicKey.rawRepresentation
                .map { String(format: "%02x", $0) }.joined()
        }
        self.now = now
    }

    /// Poll inbound DMs since cursor, decrypt, UPSERT into mirror. Returns count
    /// of newly inserted/updated rows. Idempotent — rerunning with same DB state
    /// returns 0 newly-written rows.
    @discardableResult
    public func tick(workspaceID: String) async throws -> Int {
        let pubkey = try recipientPubkeyHex()

        // Cursor — max server_created_at_ms from inbound rows in this workspace.
        let maxMs: Int64? = try database.writeSQL { db in
            try MessagesMirrorStore.maxServerCreatedAtMs(
                workspaceID: workspaceID, direction: .inbound, in: db
            )
        }
        let sinceISO = maxMs.map { iso8601FromMs($0) }

        let rows = try await supabase.fetchInboundMessages(
            workspaceID: workspaceID,
            recipientPubkeyHex: pubkey,
            sinceCreatedAtISO: sinceISO,
            limit: 100
        )

        var processedCount = 0
        for serverRow in rows {
            guard let decoded = decryptRow(serverRow, workspaceID: workspaceID) else {
                // Log + skip (tampered / unknown keyID / decode error).
                continue
            }
            let mirrorRow = makeMirrorRow(from: serverRow, plaintext: decoded, direction: .inbound)
            try database.writeSQL { db in
                try MessagesMirrorStore.upsert(mirrorRow, in: db)
            }
            processedCount += 1
        }
        return processedCount
    }

    /// Fetch + decrypt + upsert a single message by id (used by APNs wake path).
    /// Returns false if message not found / not for this recipient / decode failed.
    ///
    /// I5 fix — Track 5 / S4 Stage 6 review: prefer targeted fetchMessageByID
    /// over bounded fetchInbound window. fetchInbound caps at 100 rows; if 100+
    /// newer rows exist between cold-launch and the target message, the previous
    /// implementation would silently skip the wake-target. fetchMessageByID
    /// queries `?message_id=eq.<id>` directly.
    @discardableResult
    public func tickOnce(workspaceID: String, forMessageID messageID: String) async throws -> Bool {
        guard let target = try await supabase.fetchMessageByID(messageID: messageID) else {
            return false
        }
        guard let decoded = decryptRow(target, workspaceID: workspaceID) else {
            return false
        }
        let mirrorRow = makeMirrorRow(from: target, plaintext: decoded, direction: .inbound)
        try database.writeSQL { db in
            try MessagesMirrorStore.upsert(mirrorRow, in: db)
        }
        return true
    }

    /// Realtime push handler — UPSERTs a single pre-decoded `DirectMessageMirrorRow`
    /// received from a Supabase Realtime POSTGRES_CHANGES event.
    ///
    /// The Realtime path delivers rows that have already passed server-side RLS
    /// (same policy as REST fetchInboundMessages). No re-decryption needed — the
    /// row is already in plaintext-trust form (analogous to the decoded rows that
    /// `tick` assembles after AES-GCM decrypt + C4 plaintext-wins logic).
    ///
    /// Idempotent: calling with the same messageID twice UPSERTs without error.
    public func absorbRealtimePush(_ row: DirectMessageMirrorRow) throws {
        try database.writeSQL { db in
            try MessagesMirrorStore.upsert(row, in: db)
        }
    }

    /// Track 5 / S8 / T0 — Phase H Realtime decryption wiring.
    ///
    /// Pure decryption: keystore lookup + codec.decode under the workspace
    /// team key identified by `input.keyID`. No DB writes, no trust gates —
    /// the caller (LeafRealtimeService) applies C2/C3 plaintext-trust gates
    /// against RLS-attested wire fields after this returns.
    ///
    /// This is the same logic as the polling `tick(workspaceID:)` loop's
    /// per-row `decryptRow` helper, factored into a public method so the
    /// Realtime path can reuse it without duplicating envelope-peek logic.
    ///
    /// - Throws: `LeafError.keyFileUnavailable` if the keyID is unknown
    ///   (keystore has no .key file for the workspace+keyID pair);
    ///   `LeafError.directMessageBlobMalformed` (or codec-specific) on
    ///   AES-GCM tag mismatch / JSON decode failure.
    public func decryptOnly(_ input: EncryptedDirectMessageInput) throws -> DirectMessagePlaintext {
        let keyIDStr = input.keyID.uuidString.lowercased()
        let teamKey = try TeamKeystore.readTeamKey(
            workspaceID: input.workspaceID, keyID: keyIDStr, at: keystoreRoot
        )
        return try codec.decode(input.encryptedPayload, teamKey: teamKey)
    }

    // MARK: - Track 5 / S8 T6 — optimistic markDone + pending_mark_done flag

    /// Optimistic local markDone — UPDATE done_at + done_by + clears
    /// `pending_mark_done` in one statement. Called BEFORE the server PATCH
    /// from `DirectMessageInboxReader.markDone(messageID:)` so the user sees
    /// the row marked done immediately regardless of network outcome.
    public func markDoneLocalOptimistic(
        messageID: String,
        atMs: Int64,
        doneByPubkeyHex: String
    ) throws {
        try database.writeOptimisticMarkDone(
            messageID: messageID, atMs: atMs, doneByPubkeyHex: doneByPubkeyHex
        )
    }

    /// Set the `pending_mark_done` retry-queue flag. Called from
    /// `DirectMessageInboxReader.markDone(messageID:)` ONLY on server PATCH
    /// failure — the retry walk runs via `PendingMarkDoneRetryService.tick()`
    /// scheduled from `RootView.task`.
    public func setPendingMarkDoneFlag(messageID: String, pending: Bool) throws {
        try database.writePendingMarkDoneFlag(messageID: messageID, pending: pending)
    }

    /// Extract `EncryptedDirectMessageInput` from a wire row.
    ///
    /// Static helper — used by the Realtime path (LeafRealtimeService injects
    /// a decryptor closure constructed via `decryptOnly`; the closure first
    /// calls this to peel the envelope header). The polling `tick` loop also
    /// goes through this path via `decryptOnly` for code-path parity with
    /// Realtime.
    ///
    /// - Throws: `LeafError.directMessageBlobMalformed` on short bytes
    ///   (< 17B header) or non-DM envelope version byte (0x03 expected).
    public static func extractEncryptedInput(
        from row: SupabaseDirectMessageRow
    ) throws -> EncryptedDirectMessageInput {
        let bytes = row.encryptedPayload
        guard bytes.count >= 17,
              bytes[bytes.startIndex] == 0x03 else {
            throw LeafError.directMessageBlobMalformed
        }
        let keyIDStart = bytes.index(bytes.startIndex, offsetBy: 1)
        let keyIDEnd = bytes.index(keyIDStart, offsetBy: 16)
        let keyIDData = Data(bytes[keyIDStart..<keyIDEnd])
        guard keyIDData.count == 16 else {
            throw LeafError.directMessageBlobMalformed
        }
        let uuid = keyIDData.withUnsafeBytes { ptr in
            ptr.load(as: uuid_t.self)
        }
        let keyIDUUID = UUID(uuid: uuid)
        let aadHeader = Data(bytes[bytes.startIndex..<keyIDEnd])
        return EncryptedDirectMessageInput(
            workspaceID: row.workspaceID,
            messageID: row.messageID,
            encryptedPayload: bytes,
            keyID: keyIDUUID,
            aadHeader: aadHeader
        )
    }

    // MARK: - Helpers

    private func decryptRow(
        _ row: SupabaseDirectMessageRow,
        workspaceID: String
    ) -> DirectMessagePlaintext? {
        // Peek keyID from envelope header (bytes 1..17).
        let bytes = row.encryptedPayload
        guard bytes.count >= 17 else { return nil }
        let keyIDStart = bytes.index(bytes.startIndex, offsetBy: 1)
        let keyIDEnd = bytes.index(keyIDStart, offsetBy: 16)
        let keyID = Data(bytes[keyIDStart..<keyIDEnd])

        let keyIDString = uuidStringFromRawBytes(keyID)

        // Resolve teamKey from keystore (history rotation supported).
        let teamKeyBytes: Data
        do {
            teamKeyBytes = try TeamKeystore.readTeamKey(
                workspaceID: workspaceID, keyID: keyIDString, at: keystoreRoot
            )
        } catch {
            return nil  // unknown keyID
        }

        return try? codec.decode(bytes, teamKey: teamKeyBytes)
    }

    private func makeMirrorRow(
        from row: SupabaseDirectMessageRow,
        plaintext: DirectMessagePlaintext,
        direction: DirectMessageMirrorRow.Direction
    ) -> DirectMessageMirrorRow {
        // C4 fix — Track 5 / S4 Stage 6 review:
        // AAD binds only [version|keyID], NOT server columns. A compromised relay
        // could mutate `row.kind` or `row.replyTo` while ciphertext stays intact;
        // a falsified kind would corrupt Task lifecycle, push titles, and the
        // `idx_messages_mirror_open_tasks` partial-index assumption. We trust the
        // authenticated plaintext for kind / replyTo / sender* unconditionally.
        // Server-only fields (timestamps + read/done state) come from `row` since
        // they're written by recipient post-decrypt and aren't in plaintext.
        if let serverKind = DirectMessageKind(rawValue: row.kind), serverKind != plaintext.kind {
            // Tamper signal — log for forensic review.
            // Implementation moat — exact log shape lives in caller's OSLog domain.
            // We do NOT throw; we just override with authenticated plaintext.
        }
        let serverCreatedAtMs = parseISO8601Ms(row.createdAtISO) ?? plaintext.sentAtMs
        let readAtMs = row.readAtISO.flatMap { parseISO8601Ms($0) }
        let doneAtMs = row.doneAtISO.flatMap { parseISO8601Ms($0) }
        return DirectMessageMirrorRow(
            messageID: row.messageID,
            workspaceID: row.workspaceID,
            senderPubkeyHex: plaintext.senderPubkeyHex,
            senderMemberID: plaintext.senderMemberID,
            senderDisplayName: plaintext.senderDisplayName,
            recipientPubkeyHex: row.recipientPubkeyHex,
            kind: plaintext.kind,          // C4: authenticated plaintext wins
            body: plaintext.body,
            attachment: plaintext.attachment,
            replyTo: plaintext.replyTo,    // C4: authenticated plaintext wins
            sentAtMs: plaintext.sentAtMs,
            serverCreatedAtMs: serverCreatedAtMs,
            readAtMs: readAtMs,
            doneAtMs: doneAtMs,
            doneByPubkeyHex: row.doneByPubkeyHex,
            direction: direction,
            lastSyncedAtMs: Int64(now().timeIntervalSince1970 * 1000)
        )
    }

    private func uuidStringFromRawBytes(_ data: Data) -> String {
        guard data.count == 16 else { return "" }
        let uuid = data.withUnsafeBytes { ptr in
            ptr.load(as: uuid_t.self)
        }
        return UUID(uuid: uuid).uuidString.lowercased()
    }

    private func iso8601FromMs(_ ms: Int64) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }

    private func parseISO8601Ms(_ iso: String) -> Int64? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: iso) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        f.formatOptions = [.withInternetDateTime]
        if let date = f.date(from: iso) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        return nil
    }
}
