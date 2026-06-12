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
    /// Resolves THIS device's identity pubkey hex (lowercased) — the same source
    /// the JWT `pubkey` claim is derived from. Used to pick `selfMember` out of
    /// the roster BY IDENTITY, not `members.first`: `readTeamMembers` is
    /// `ORDER BY added_at_ms ASC`, so on a joiner's device the first row is the
    /// workspace creator (earlier timestamp), not self. Baking the creator's
    /// pubkey into the encrypted plaintext makes the recipient's C2 trust-gate
    /// (`plaintext.sender == row.sender`) silently drop the message. Same
    /// foot-gun already fixed in InviteTokensReader.
    private let selfPubkeyHex: @Sendable () throws -> String

    public init(
        database: Database,
        supabase: SupabaseClient,
        codec: any DirectMessageBlobCodec,
        keystoreRoot: URL = TeamKeystore.defaultRoot(),
        now: @escaping @Sendable () -> Date = { Date() },
        generateMessageID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        selfPubkeyHex: (@Sendable () throws -> String)? = nil
    ) {
        self.database = database
        self.supabase = supabase
        self.codec = codec
        self.keystoreRoot = keystoreRoot
        self.now = now
        self.generateMessageID = generateMessageID
        let root = keystoreRoot
        self.selfPubkeyHex = selfPubkeyHex ?? {
            let priv = try IdentityService.ensureLocalIdentity(at: root)
            return priv.publicKey.rawRepresentation
                .map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Sender path — full pipeline: validate → encode → POST → mirror INSERT →
    /// (optional) APNs push trigger → (optional) cross-post triggers (S6).
    /// APNs + cross-post failures are non-fatal — message persists;
    /// pushDispatchStatus / crossPostStatuses carry the reasons.
    public func send(
        workspaceID: String,
        recipientPubkeyHex: String,
        recipientMemberID: String?,
        kind: DirectMessageKind,
        body: String,
        notify: Bool = true,
        replyTo: String? = nil,
        contextSnapshot: HandoffContextSnapshot? = nil,
        crossPostSlack: SlackCrossPostRequest? = nil,
        crossPostLinear: LinearCrossPostRequest? = nil
    ) async throws -> SentDirectMessage {
        // Track C (UC-4) — the structured card is a handoff affordance only.
        let resolvedSnapshot = kind == .handoff ? contextSnapshot : nil
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
        // Resolve self BY IDENTITY, not `members.first` (= added_at_ms ASC = the
        // workspace creator on a joiner's device). The sender baked into the
        // encrypted plaintext must equal the JWT pubkey the recipient's C2
        // trust-gate attests against, or every DM is silently dropped on receive.
        let selfPub = try selfPubkeyHex().lowercased()
        guard let selfMember = members.first(where: { $0.pubkeyHex.lowercased() == selfPub }) else {
            throw LeafError.databaseUnavailable
        }
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
            contextSnapshot: resolvedSnapshot,
            replyTo: replyTo,
            sentAtMs: nowMs
        )

        // 4. Encrypt — keyID is 16-byte raw UUID
        let keyIDData = Data(try uuidStringToRawBytes(activeKey.id))
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
            contextSnapshot: resolvedSnapshot,
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

        // 7. (Optional) APNs trigger — fired in parallel with the cross-post
        // legs below so the Send wall-clock is `max(apns, slack, linear)`,
        // not their sum. The DM row already persisted on line 144-146; APNs
        // is purely best-effort and its outcome reported via
        // `pushDispatchStatus` (the `.failed(_)` variant never throws).
        //
        // Track 5 / S8 / T5 — `kind.rawValue` forwarded to the Edge Function
        // for category binding (`aps.category = "leaf.dm.<kind>"`),
        // thread-id format (`<workspace_id>:<kind>`), and notification_prefs
        // server-side skip check. When the server returns `skipped_by_prefs`,
        // the SDK reports `.sent` (recipient opted out is expected, not a
        // failure — the message itself persisted successfully).
        async let apnsStatus: SentDirectMessage.PushDispatchStatus = {
            guard notify else { return .skipped }
            do {
                _ = try await supabase.triggerAPNsPush(
                    workspaceID: workspace.id,
                    recipientPubkeyHex: recipientPubkeyHex.lowercased(),
                    messageID: supabaseRow.messageID,
                    titleText: pushTitle(sender: selfMember.displayName, kind: kind),
                    kind: kind.rawValue
                )
                return .sent
            } catch {
                return .failed(String(describing: error))
            }
        }()

        // 8. (Optional) Cross-post triggers — S6.
        //
        // Run after the DM has been persisted (direct_messages row exists +
        // mirror row written) so that cross_post_log.message_id FK is valid
        // and a retry yields a consistent external_ref. Slack and Linear legs
        // execute in parallel via `async let` — they have no inter-dependency
        // and we want UI to render both statuses ≤ a single network RTT.
        //
        // Failure semantics (§9.3): each leg captures its error into the
        // result struct. Throws are NEVER propagated; the DM row remains
        // valid regardless of cross-post outcome.
        async let crossPostStatusesTask = runCrossPosts(
            workspaceID: workspace.id,
            messageID: supabaseRow.messageID,
            body: body,
            crossPostSlack: crossPostSlack,
            crossPostLinear: crossPostLinear
        )

        let pushStatus = await apnsStatus
        let crossPostStatuses = await crossPostStatusesTask

        return SentDirectMessage(
            messageID: supabaseRow.messageID,
            createdAtISO: supabaseRow.createdAtISO,
            pushDispatchStatus: pushStatus,
            crossPostStatuses: crossPostStatuses
        )
    }

    /// S6 — Cross-post fan-out. Slack + Linear legs execute in parallel via
    /// `async let`. Each leg:
    ///   1. Returns nil immediately when the corresponding param is nil.
    ///   2. Reads the sender's integration record from local SQLCipher; when
    ///      absent returns `.error="not_connected"` WITHOUT calling the Edge
    ///      Function (avoids leaking sender presence on the wire when there's
    ///      no chance of success).
    ///   3. Builds the payload via `CrossPostPayloadBuilder` and forwards to
    ///      the appropriate Edge Function.
    ///   4. Catches any throw + maps to `.error=<descrip>` result — NEVER
    ///      propagates upstream (DM row already persisted).
    private func runCrossPosts(
        workspaceID: String,
        messageID: String,
        body: String,
        crossPostSlack: SlackCrossPostRequest?,
        crossPostLinear: LinearCrossPostRequest?
    ) async -> CrossPostStatuses {
        async let slackResult: SlackCrossPostResult? = runSlackCrossPost(
            workspaceID: workspaceID,
            messageID: messageID,
            body: body,
            request: crossPostSlack
        )
        async let linearResult: LinearCrossPostResult? = runLinearCrossPost(
            workspaceID: workspaceID,
            messageID: messageID,
            body: body,
            request: crossPostLinear
        )
        let slack = await slackResult
        let linear = await linearResult
        return CrossPostStatuses(slack: slack, linear: linear)
    }

    private func runSlackCrossPost(
        workspaceID: String,
        messageID: String,
        body: String,
        request: SlackCrossPostRequest?
    ) async -> SlackCrossPostResult? {
        guard let req = request else { return nil }
        // Integration lookup — local DB read on a non-throwing branch. Map
        // any DB error AND missing-row both to "not_connected" so UI flow is
        // identical (user reauths via Connections regardless of cause).
        let token: String
        do {
            guard let integration = try database.readIntegration(provider: .slack) else {
                return SlackCrossPostResult(
                    ok: false, ts: nil, channelID: req.channelID,
                    error: "not_connected", retryAfterSeconds: nil
                )
            }
            token = integration.accessToken
        } catch {
            return SlackCrossPostResult(
                ok: false, ts: nil, channelID: req.channelID,
                error: "not_connected", retryAfterSeconds: nil
            )
        }
        guard let workspaceUUID = UUID(uuidString: workspaceID),
              let messageUUID = UUID(uuidString: messageID) else {
            return SlackCrossPostResult(
                ok: false, ts: nil, channelID: req.channelID,
                error: "invalid_uuid", retryAfterSeconds: nil
            )
        }
        let payload = CrossPostPayloadBuilder.slackPayload(
            channelID: req.channelID,
            messageText: body,
            attachedEventRef: req.attachedEventRef
        )
        do {
            return try await supabase.triggerSlackPost(
                workspaceID: workspaceUUID,
                messageID: messageUUID,
                channelID: req.channelID,
                slackPayload: payload,
                slackUserToken: token
            )
        } catch {
            return SlackCrossPostResult(
                ok: false, ts: nil, channelID: req.channelID,
                error: String(describing: error), retryAfterSeconds: nil
            )
        }
    }

    private func runLinearCrossPost(
        workspaceID: String,
        messageID: String,
        body: String,
        request: LinearCrossPostRequest?
    ) async -> LinearCrossPostResult? {
        guard let req = request else { return nil }
        let token: String
        do {
            guard let integration = try database.readIntegration(provider: .linear) else {
                return LinearCrossPostResult(
                    ok: false, issueID: nil, identifier: nil, url: nil,
                    error: "not_connected"
                )
            }
            token = integration.accessToken
        } catch {
            return LinearCrossPostResult(
                ok: false, issueID: nil, identifier: nil, url: nil,
                error: "not_connected"
            )
        }
        guard let workspaceUUID = UUID(uuidString: workspaceID),
              let messageUUID = UUID(uuidString: messageID) else {
            return LinearCrossPostResult(
                ok: false, issueID: nil, identifier: nil, url: nil,
                error: "invalid_uuid"
            )
        }
        let title = CrossPostPayloadBuilder.linearTitle(messageText: body)
        let description = CrossPostPayloadBuilder.linearDescription(
            messageText: body,
            messageID: messageUUID,
            attachedEventRef: req.attachedEventRef
        )
        do {
            return try await supabase.triggerLinearCreate(
                workspaceID: workspaceUUID,
                messageID: messageUUID,
                teamID: req.teamID,
                idempotencyKey: req.idempotencyKey,
                title: title,
                description: description,
                assigneeID: req.assigneeID,
                linearUserToken: token
            )
        } catch {
            return LinearCrossPostResult(
                ok: false, issueID: nil, identifier: nil, url: nil,
                error: String(describing: error)
            )
        }
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

    private func uuidStringToRawBytes(_ s: String) throws -> [UInt8] {
        guard let uuid = UUID(uuidString: s) else {
            throw LeafError.invalidPayload
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
