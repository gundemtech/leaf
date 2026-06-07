//
//  TeamEventBroadcastService.swift
//  LeafCore
//
//  Track 5 / S5 — sender-side broadcast loop. Reads events table since the
//  per-workspace cursor, runs filter chain (classify → share_rules → denylist),
//  encodes under workspace teamKey via injected codec (version 0x04), POSTs to
//  Supabase `team_events` with `expires_at = now + 30d`, advances cursor.
//
//  Filter order per Track 5 contract §11.2:
//    1. ShareSourceClassifier.classify(eventKind) — nil → skip + advance.
//    2. ShareRulesStore.isEnabled(source) — false → skip + advance.
//    3. DefaultDenyList.matches(eventKind, payload) — true → skip + advance.
//    4. Otherwise: TeamEventPayloadBuilder.build → codec.encode →
//       SupabaseClient.sendTeamEvent → advance.
//
//  Halt-on-network-failure, skip-on-validation-failure semantics (spec §8.1):
//  network errors do not advance cursor (retried next tick); validation /
//  encryption errors skip the offending event so the loop doesn't deadlock.
//

import CryptoKit
import Foundation
import GRDB
import OSLog

public struct BroadcastTickResult: Sendable, Equatable {
    public let processedCount: Int
    public let sentCount: Int
    public let skippedCount: Int

    public init(processedCount: Int, sentCount: Int, skippedCount: Int) {
        self.processedCount = processedCount
        self.sentCount = sentCount
        self.skippedCount = skippedCount
    }
}

/// Thin row projection used by the broadcast service so the rest of the loop
/// works against value types (not GRDB.Row). The loop pulls only fields it
/// needs: events.id, payload event_kind, ts, full payload bag.
public struct BroadcastEventCandidate: Sendable, Equatable {
    public let id: Int64
    public let eventKind: String
    public let tsMs: Int64
    public let payload: [String: String]

    public init(id: Int64, eventKind: String, tsMs: Int64, payload: [String: String]) {
        self.id = id
        self.eventKind = eventKind
        self.tsMs = tsMs
        self.payload = payload
    }
}

public actor TeamEventBroadcastService {

    /// Retention budget — auto-shared events expire on the server after 30 days
    /// (Track 5 contract §13). Local mirror retention is independent (90d
    /// default; `TeamEventMirrorRetentionPruner`).
    public static let retentionDays: Int = 30

    public static let defaultBatchLimit: Int = 100

    private let database: LeafCore.Database
    private let supabase: SupabaseClient
    private let codec: any TeamEventBlobCodec
    private let keystoreRoot: URL
    private let classifier: ShareSourceClassifier
    private let denyList: DefaultDenyList
    private let now: @Sendable () -> Date
    private let batchLimit: Int
    private let logger: Logger
    /// Resolves THIS device's identity pubkey hex (lowercased). See
    /// `DirectMessageService.selfPubkeyHex` — `members.first` is the workspace
    /// creator on a joiner's device, so a joiner's broadcasts would be signed
    /// with the admin's pubkey and silently dropped by the recipient C2 gate.
    private let selfPubkeyHex: @Sendable () throws -> String

    public init(
        database: LeafCore.Database,
        supabase: SupabaseClient,
        codec: any TeamEventBlobCodec,
        keystoreRoot: URL = TeamKeystore.defaultRoot(),
        classifier: ShareSourceClassifier = ShareSourceClassifier(),
        denyList: DefaultDenyList = DefaultDenyList(),
        now: @escaping @Sendable () -> Date = { Date() },
        batchLimit: Int = defaultBatchLimit,
        logger: Logger = Logger(subsystem: "tech.gundem.leaf.core", category: "team-event-broadcast"),
        selfPubkeyHex: (@Sendable () throws -> String)? = nil
    ) {
        self.database = database
        self.supabase = supabase
        self.codec = codec
        self.keystoreRoot = keystoreRoot
        self.classifier = classifier
        self.denyList = denyList
        self.now = now
        self.batchLimit = batchLimit
        self.logger = logger
        let root = keystoreRoot
        self.selfPubkeyHex = selfPubkeyHex ?? {
            let priv = try IdentityService.ensureLocalIdentity(at: root)
            return priv.publicKey.rawRepresentation
                .map { String(format: "%02x", $0) }.joined()
        }
    }

    /// One tick — read since cursor, filter, encrypt, POST batch. Returns
    /// processed / sent / skipped counts. Throws on network failure (cursor
    /// not advanced; retried next tick).
    @discardableResult
    public func tick(workspaceID: String) async throws -> BroadcastTickResult {
        let nowDate = now()
        let nowMs = Int64(nowDate.timeIntervalSince1970 * 1000)

        // Resolve workspace + sender + active teamKey on every tick (cheap reads;
        // these may rotate between ticks).
        guard let workspace = try database.readWorkspace(id: workspaceID) else {
            throw LeafError.databaseUnavailable
        }
        let members = try database.readTeamMembers(workspaceID: workspace.id, includeRemoved: false)
        // Self BY IDENTITY, not `members.first` (= creator on a joiner device).
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

        // I2 Stage 6 review fix — cursor + isEnabled read via pool.read (not
        // writer pool). Reduces lock contention with Agent writer thread.
        let cursor = try database.readSQL { rawDB -> TeamEventBroadcastOffset in
            try TeamEventBroadcastOffsetsStore.readOrDefault(workspaceID: workspace.id, in: rawDB)
        }
        let candidates = try database.readSQL { rawDB -> [BroadcastEventCandidate] in
            try Self.fetchCandidates(afterEventID: cursor.cursorEventID, limit: self.batchLimit, in: rawDB)
        }
        guard !candidates.isEmpty else {
            // I6 Stage 6 review fix — even empty ticks record success so
            // last_success_at_ms tracks "last poll attempt that worked".
            try database.writeSQL { rawDB in
                try TeamEventBroadcastOffsetsStore.recordSuccess(
                    workspaceID: workspace.id, nowMs: nowMs, in: rawDB
                )
            }
            return BroadcastTickResult(processedCount: 0, sentCount: 0, skippedCount: 0)
        }

        // I2 — cache effective rules per tick (avoids per-event SQL roundtrip).
        let effectiveRules = try database.readShareRules(workspaceID: workspace.id)

        var sent = 0
        var skipped = 0
        var processed = 0
        for candidate in candidates {
            processed += 1
            let dispatch = classifyAndFilter(
                candidate: candidate, effectiveRules: effectiveRules
            )
            switch dispatch {
            case .skip(let reason):
                skipped += 1
                logger.debug("broadcast skip event=\(candidate.id, privacy: .public) reason=\(reason, privacy: .public)")
                try database.writeSQL { rawDB in
                    try TeamEventBroadcastOffsetsStore.advanceCursor(
                        workspaceID: workspace.id, toEventID: candidate.id, in: rawDB
                    )
                }
            case .send(let source):
                do {
                    // C4 Stage 6 review fix — deterministic eventID per local
                    // events.id + workspaceID. Retry after transient network
                    // failure regenerates the same UUID so server-side
                    // merge-duplicates can detect + dedupe.
                    let determinedEventID = Self.deterministicEventID(
                        workspaceID: workspace.id, localEventID: candidate.id
                    )
                    let plaintext = TeamEventPlaintext(
                        eventID: determinedEventID,
                        workspaceID: workspace.id,
                        senderMemberID: selfMember.id,
                        senderPubkeyHex: selfMember.pubkeyHex,
                        source: source,
                        kind: candidate.eventKind,
                        payload: TeamEventPayloadBuilder.build(source: source, payload: candidate.payload),
                        eventTsMs: candidate.tsMs
                    )
                    let keyIDData = try Self.uuidStringToRawBytes(activeKey.id)
                    let envelope = try codec.encode(
                        plaintext, keyID: keyIDData, teamKey: teamKeyBytes
                    )
                    let expiresAt = nowDate.addingTimeInterval(TimeInterval(Self.retentionDays * 86_400))
                    _ = try await supabase.sendTeamEvent(
                        workspaceID: workspace.id,
                        eventID: plaintext.eventID,
                        sourceKind: source.rawValue,
                        kind: candidate.eventKind,
                        encryptedPayload: envelope,
                        expiresAt: expiresAt
                    )
                    sent += 1
                    try database.writeSQL { rawDB in
                        try TeamEventBroadcastOffsetsStore.advanceCursor(
                            workspaceID: workspace.id, toEventID: candidate.id, in: rawDB
                        )
                    }
                } catch let supabaseError as SupabaseError {
                    // Network / RLS / server failures — record failure and halt
                    // cursor (do not advance). Caller retries next tick.
                    try database.writeSQL { rawDB in
                        try TeamEventBroadcastOffsetsStore.recordFailure(
                            workspaceID: workspace.id, nowMs: nowMs, in: rawDB
                        )
                    }
                    logger.error("broadcast halt event=\(candidate.id, privacy: .public): \(String(describing: supabaseError), privacy: .public)")
                    throw supabaseError
                } catch {
                    // Encoding / encryption errors are non-network: skip + advance.
                    skipped += 1
                    logger.error("broadcast skip-on-encode-fail event=\(candidate.id, privacy: .public): \(String(describing: error), privacy: .public)")
                    try database.writeSQL { rawDB in
                        try TeamEventBroadcastOffsetsStore.advanceCursor(
                            workspaceID: workspace.id, toEventID: candidate.id, in: rawDB
                        )
                    }
                }
            }
        }

        try database.writeSQL { rawDB in
            try TeamEventBroadcastOffsetsStore.recordSuccess(
                workspaceID: workspace.id, nowMs: nowMs, in: rawDB
            )
        }
        return BroadcastTickResult(processedCount: processed, sentCount: sent, skippedCount: skipped)
    }

    // MARK: - Internals

    private enum Dispatch {
        case skip(reason: String)
        case send(source: ShareSource)
    }

    private func classifyAndFilter(
        candidate: BroadcastEventCandidate,
        effectiveRules: [ShareSource: Bool]
    ) -> Dispatch {
        guard let source = classifier.classify(eventKind: candidate.eventKind) else {
            return .skip(reason: "unmapped")
        }
        let enabled = effectiveRules[source] ?? ShareRuleDefaults.isEnabledByDefault(source)
        guard enabled else {
            return .skip(reason: "rule_off")
        }
        if denyList.matches(eventKind: candidate.eventKind, payload: candidate.payload) {
            return .skip(reason: "denylist")
        }
        return .send(source: source)
    }

    /// C4 Stage 6 review fix — deterministic UUID derived from
    /// (workspaceID, local events.id). Repeated calls with the same args
    /// return the exact same UUID, so retry after transient network failure
    /// hits the server's merge-duplicates path instead of double-inserting.
    /// Uses SHA-256 → first 16 bytes formatted as UUID (RFC 4122 §4.4
    /// version 4 layout with the version + variant bits set per spec).
    /// Not collision-attack-grade — but workspaceID is a UUID itself, so
    /// the namespace is 128-bit-distinguishable; collisions across
    /// workspaces require deliberate effort that buys the attacker
    /// nothing (target workspace would have to fetch a rebroadcast of
    /// its own row).
    static func deterministicEventID(workspaceID: String, localEventID: Int64) -> String {
        let input = "\(workspaceID):\(localEventID)"
        let digest = SHA256.hash(data: Data(input.utf8))
        var bytes = Array(digest.prefix(16))
        // RFC 4122 §4.4 — set version (4) and variant (RFC 4122) bits.
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return uuid.uuidString.lowercased()
    }

    static func uuidStringToRawBytes(_ s: String) throws -> Data {
        guard let uuid = UUID(uuidString: s) else {
            throw LeafError.invalidPayload
        }
        return withUnsafeBytes(of: uuid.uuid) { Data($0) }
    }

    /// Read up to `limit` events with id > cursorEventID, ordered by id ASC.
    /// payload_json deserialized to [String: String] (event payloads are flat
    /// string maps by Layer A/B convention).
    static func fetchCandidates(
        afterEventID cursorEventID: Int64,
        limit: Int,
        in rawDB: GRDB.Database
    ) throws -> [BroadcastEventCandidate] {
        let rows = try Row.fetchAll(
            rawDB,
            sql: """
                SELECT id, ts, payload_json
                FROM \(Schema.Events.tableName)
                WHERE id > ?
                ORDER BY id ASC
                LIMIT ?
                """,
            arguments: [cursorEventID, limit]
        )
        return rows.compactMap { row -> BroadcastEventCandidate? in
            guard
                let id = row["id"] as Int64?,
                let ts = row["ts"] as Int64?,
                let payloadJSON = row["payload_json"] as String?
            else { return nil }

            guard let payloadData = payloadJSON.data(using: .utf8),
                  let parsed = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any] else {
                return nil
            }
            var payload: [String: String] = [:]
            for (k, v) in parsed {
                if let s = v as? String {
                    payload[k] = s
                } else if let n = v as? NSNumber {
                    payload[k] = n.stringValue
                } else if let b = v as? Bool {
                    payload[k] = b ? "true" : "false"
                }
                // Drop other types (arrays / objects) — Layer A/B convention is flat string map.
            }
            let kind = payload["event_kind"] ?? ""
            guard !kind.isEmpty else { return nil }
            return BroadcastEventCandidate(id: id, eventKind: kind, tsMs: ts, payload: payload)
        }
    }
}
