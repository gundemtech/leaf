//
//  DirectMessageService.swift
//  LeafCore
//
//  Track 5 / S4 — sender-side orchestrator for direct messages. Encrypts a
//  DirectMessagePlaintext under the active workspace teamKey via the injected
//  codec, POSTs to Supabase direct_messages, writes own outbound row to local
//  messages_mirror, optionally fires apns_push (fire-and-forget).
//
//  Mirror invariant: sender's row gets `direction='outbound'`, recipient's poll
//  via DirectMessageInboxService writes `direction='inbound'`. Same message_id
//  appears once per Mac per side.
//

import CryptoKit
import Foundation

public struct DirectMessageService: Sendable {
    /// Body length cap (safety) — 64KB plaintext before AES-GCM expansion.
    public static let bodyMaxBytes: Int = 64 * 1024

    private let database: Database
    private let supabase: SupabaseClient
    private let codec: any DirectMessageBlobCodec
    private let keystoreRoot: URL
    private let now: @Sendable () -> Date
    private let generateMessageID: @Sendable () -> String

    public init(
        database: Database,
        supabase: SupabaseClient,
        codec: any DirectMessageBlobCodec,
        keystoreRoot: URL = TeamKeystore.defaultRoot(),
        now: @escaping @Sendable () -> Date = { Date() },
        generateMessageID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.database = database
        self.supabase = supabase
        self.codec = codec
        self.keystoreRoot = keystoreRoot
        self.now = now
        self.generateMessageID = generateMessageID
    }

    /// Sender path — full pipeline: validate → encode → POST → mirror INSERT →
    /// (optional) APNs push trigger. APNs failures are non-fatal — message
    /// persists; pushDispatchStatus carries the reason.
    public func send(
        workspaceID: String,
        recipientPubkeyHex: String,
        recipientMemberID: String?,
        kind: DirectMessageKind,
        body: String,
        notify: Bool = true,
        replyTo: String? = nil
    ) async throws -> SentDirectMessage {
        // 1. Validate
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty else { throw LeafError.invalidPayload }
        let bodyByteCount = body.utf8.count
        guard bodyByteCount <= Self.bodyMaxBytes else {
            throw LeafError.directMessageBodyTooLarge
        }
        guard recipientPubkeyHex.count == 64,
              recipientPubkeyHex.allSatisfy({ $0.isHexDigit }) else {
            throw LeafError.invalidPayload
        }

        // 2. Resolve workspace + sender + active teamKey
        guard let workspace = try database.readWorkspace(id: workspaceID) else {
            throw LeafError.databaseUnavailable
        }
        let members = try database.readTeamMembers(workspaceID: workspace.id, includeRemoved: false)
        guard let selfMember = members.first else { throw LeafError.databaseUnavailable }
        guard let activeKey = try database.readActiveTeamKey(workspaceID: workspace.id) else {
            throw LeafError.databaseUnavailable
        }
        let teamKeyBytes = try TeamKeystore.readTeamKey(
            workspaceID: workspace.id, keyID: activeKey.id, at: keystoreRoot
        )

        // 3. Build plaintext
        let messageID = generateMessageID()
        let nowDate = now()
        let nowMs = Int64(nowDate.timeIntervalSince1970 * 1000)
        let plaintext = DirectMessagePlaintext(
            messageID: messageID,
            workspaceID: workspace.id,
            senderMemberID: selfMember.id,
            senderPubkeyHex: selfMember.pubkeyHex,
            senderDisplayName: selfMember.displayName,
            recipientMemberID: recipientMemberID,
            recipientPubkeyHex: recipientPubkeyHex.lowercased(),
            kind: kind,
            body: body,
            attachment: nil,  // S4 always nil; S5 will populate
            replyTo: replyTo,
            sentAtMs: nowMs
        )

        // 4. Encrypt — keyID is 16-byte raw UUID
        let keyIDData = Data(uuidStringToRawBytes(activeKey.id))
        let envelope = try codec.encode(plaintext, keyID: keyIDData, teamKey: teamKeyBytes)

        // 5. POST to Supabase
        let supabaseRow: SupabaseSentMessageRow
        do {
            supabaseRow = try await supabase.sendDirectMessage(
                workspaceID: workspace.id,
                recipientPubkeyHex: recipientPubkeyHex.lowercased(),
                kind: kind,
                encryptedPayload: envelope,
                replyTo: replyTo
            )
        } catch {
            // Local mirror not written — sender retries from UI.
            throw error
        }

        // 6. Mirror INSERT (outbound)
        let serverCreatedAtMs = parseISO8601Ms(supabaseRow.createdAtISO) ?? nowMs
        let outboundRow = DirectMessageMirrorRow(
            messageID: supabaseRow.messageID,
            workspaceID: workspace.id,
            senderPubkeyHex: selfMember.pubkeyHex,
            senderMemberID: selfMember.id,
            senderDisplayName: selfMember.displayName,
            recipientPubkeyHex: recipientPubkeyHex.lowercased(),
            kind: kind,
            body: body,
            attachment: nil,
            replyTo: replyTo,
            sentAtMs: nowMs,
            serverCreatedAtMs: serverCreatedAtMs,
            readAtMs: nil,
            doneAtMs: nil,
            doneByPubkeyHex: nil,
            direction: .outbound,
            lastSyncedAtMs: serverCreatedAtMs
        )
        try database.writeSQL { db in
            try MessagesMirrorStore.upsert(outboundRow, in: db)
        }

        // 7. (Optional) APNs trigger — fire-and-forget but capture status
        let pushStatus: SentDirectMessage.PushDispatchStatus
        if notify {
            do {
                _ = try await supabase.triggerAPNsPush(
                    workspaceID: workspace.id,
                    recipientPubkeyHex: recipientPubkeyHex.lowercased(),
                    messageID: supabaseRow.messageID,
                    titleText: pushTitle(sender: selfMember.displayName, kind: kind)
                )
                pushStatus = .sent
            } catch {
                pushStatus = .failed(String(describing: error))
            }
        } else {
            pushStatus = .skipped
        }

        return SentDirectMessage(
            messageID: supabaseRow.messageID,
            createdAtISO: supabaseRow.createdAtISO,
            pushDispatchStatus: pushStatus
        )
    }

    /// I4 fix — Track 5 / S4 Stage 6 review:
    /// Server PATCH + local mirror UPDATE in one call. Without this wrapper,
    /// UI invoking just supabase.markRead leaves mirror stale until next tick
    /// (which never fired pre-Stage-6 due to missing scheduler).
    public func markRead(messageID: String) async throws {
        let nowDate = now()
        let iso = Self.iso8601(from: nowDate)
        try await supabase.markRead(messageID: messageID, readAtISO: iso)
        let nowMs = Int64(nowDate.timeIntervalSince1970 * 1000)
        try database.writeSQL { db in
            try MessagesMirrorStore.markRead(messageID: messageID, atMs: nowMs, in: db)
        }
    }

    /// I4 fix — server PATCH + local mirror UPDATE for Task done lifecycle.
    public func markDone(messageID: String, doneByPubkeyHex: String) async throws {
        let nowDate = now()
        let iso = Self.iso8601(from: nowDate)
        try await supabase.markDone(
            messageID: messageID, doneAtISO: iso, doneByPubkeyHex: doneByPubkeyHex
        )
        let nowMs = Int64(nowDate.timeIntervalSince1970 * 1000)
        try database.writeSQL { db in
            try MessagesMirrorStore.markDone(
                messageID: messageID, atMs: nowMs,
                doneByPubkeyHex: doneByPubkeyHex, in: db
            )
        }
    }

    private static func iso8601(from date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    // MARK: - Helpers

    private func pushTitle(sender: String, kind: DirectMessageKind) -> String {
        switch kind {
        case .handoff: return "\(sender) sent a handoff"
        case .task:    return "\(sender) assigned a task"
        case .ping:    return "\(sender) pinged you"
        }
    }

    private func uuidStringToRawBytes(_ s: String) -> [UInt8] {
        guard let uuid = UUID(uuidString: s) else {
            return Array(repeating: 0, count: 16)
        }
        return withUnsafeBytes(of: uuid.uuid) { Array($0) }
    }

    private func parseISO8601Ms(_ iso: String) -> Int64? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: iso) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: iso) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        return nil
    }
}
