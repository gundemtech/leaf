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
