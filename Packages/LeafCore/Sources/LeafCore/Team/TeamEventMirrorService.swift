//
//  TeamEventMirrorService.swift
//  LeafCore
//
//  Track 5 / S5 — recipient-side mirror loop. Per workspace tick:
//    1. Read MAX(server_created_at_ms) watermark from team_events_mirror.
//    2. SupabaseClient.fetchInboundTeamEvents since watermark.
//    3. For each row: peek 17B header (1B version=0x04 + 16B keyID) →
//       keystore lookup → codec.decode → UPSERT into team_events_mirror.
//
//  Trust model: AAD binds version + keyID only. The plaintext source / kind
//  are authoritative — server-controlled `source_kind` / `kind` columns are
//  used only for query-time filtering, never for trust decisions on the
//  decoded plaintext (matches DirectMessageInboxService C4 precedent).
//
//  Per-row failures (unknown keyID, decode fail, tag mismatch) are logged +
//  skipped — the loop continues so one bad row does not block the watermark.
//

import Foundation
import GRDB
import OSLog

public struct MirrorTickResult: Sendable, Equatable {
    public let fetchedCount: Int
    public let decodedCount: Int
    public let upsertedCount: Int

    public init(fetchedCount: Int, decodedCount: Int, upsertedCount: Int) {
        self.fetchedCount = fetchedCount
        self.decodedCount = decodedCount
        self.upsertedCount = upsertedCount
    }
}

public actor TeamEventMirrorService {

    public static let defaultBatchLimit: Int = 100

    /// Header prefix: 1B version + 16B keyID. Matches presence /
    /// invite / DM / team-event envelope discipline.
    public static let envelopeHeaderSize: Int = 17
    public static let teamEventEnvelopeVersion: UInt8 = 0x04

    private let database: LeafCore.Database
    private let supabase: SupabaseClient
    private let codec: any TeamEventBlobCodec
    private let keystoreRoot: URL
    private let now: @Sendable () -> Date
    private let batchLimit: Int
    private let logger: Logger

    public init(
        database: LeafCore.Database,
        supabase: SupabaseClient,
        codec: any TeamEventBlobCodec,
        keystoreRoot: URL = TeamKeystore.defaultRoot(),
        now: @escaping @Sendable () -> Date = { Date() },
        batchLimit: Int = defaultBatchLimit,
        logger: Logger = Logger(subsystem: "tech.gundem.leaf.core", category: "team-event-mirror")
    ) {
        self.database = database
        self.supabase = supabase
        self.codec = codec
        self.keystoreRoot = keystoreRoot
        self.now = now
        self.batchLimit = batchLimit
        self.logger = logger
    }

    @discardableResult
    public func tick(workspaceID: String) async throws -> MirrorTickResult {
        // Validate workspace before issuing the network call.
        guard try database.readWorkspace(id: workspaceID) != nil else {
            throw LeafError.databaseUnavailable
        }

        let watermarkMs = try database.readSQL { rawDB -> Int64? in
            try TeamEventMirrorStore.maxServerCreatedAtMs(workspaceID: workspaceID, in: rawDB)
        }
        let rows = try await supabase.fetchInboundTeamEvents(
            workspaceID: workspaceID, sinceCreatedAtMs: watermarkMs, limit: batchLimit
        )
        guard !rows.isEmpty else {
            return MirrorTickResult(fetchedCount: 0, decodedCount: 0, upsertedCount: 0)
        }

        var decoded = 0
        var upserted = 0
        var batchedRows: [TeamEventMirrorRow] = []
        let receivedAtMs = Int64(now().timeIntervalSince1970 * 1000)
        for row in rows {
            do {
                let bytes = row.encryptedPayload
                guard bytes.count >= Self.envelopeHeaderSize,
                      bytes[bytes.startIndex] == Self.teamEventEnvelopeVersion else {
                    logger.warning("mirror skip — bad envelope header for event=\(row.eventID, privacy: .public)")
                    continue
                }
                let keyIDStart = bytes.index(bytes.startIndex, offsetBy: 1)
                let keyIDEnd = bytes.index(keyIDStart, offsetBy: 16)
                let keyID = Data(bytes[keyIDStart..<keyIDEnd])
                let keyIDStr = Self.keyIDDataToUUIDString(keyID)
                let teamKey: Data
                do {
                    teamKey = try TeamKeystore.readTeamKey(
                        workspaceID: workspaceID, keyID: keyIDStr, at: keystoreRoot
                    )
                } catch {
                    logger.warning("mirror skip — unknown keyID for event=\(row.eventID, privacy: .public)")
                    continue
                }
                let plaintext = try codec.decode(bytes, teamKey: teamKey)
                decoded += 1

                // C2 Stage 6 review fix — sender impersonation guard.
                // AAD only binds version + keyID; encrypted plaintext is
                // sender-controlled. Server-side RLS attests that
                // row.senderPubkeyHex matches the JWT pubkey of whoever
                // INSERTed, so server-attested field is authoritative.
                // If plaintext claim disagrees, treat as impersonation
                // attempt and drop. Compare lowercased to dodge case drift.
                guard plaintext.senderPubkeyHex.lowercased()
                        == row.senderPubkeyHex.lowercased() else {
                    logger.warning("mirror skip — sender impersonation suspect for event=\(row.eventID, privacy: .public)")
                    continue
                }

                // C3 Stage 6 review fix — cross-workspace leak guard.
                // The fetch was scoped to the polling workspaceID (RLS
                // enforces workspace membership). If plaintext claims a
                // different workspaceID, attacker is trying to leak rows
                // from workspace X into workspace Y. Drop.
                guard plaintext.workspaceID == workspaceID else {
                    logger.warning("mirror skip — workspace mismatch for event=\(row.eventID, privacy: .public)")
                    continue
                }

                // Trust plaintext source/kind over server-controlled columns
                // (precedent: S4 DM C4 fix). AAD only binds version + keyID,
                // so server could mutate sourceKind/kind columns — discard.
                // Sender pubkey + workspace ID — server-attested (above).
                let mirrorRow = TeamEventMirrorRow(
                    eventID: plaintext.eventID,
                    workspaceID: workspaceID,
                    senderPubkeyHex: row.senderPubkeyHex,
                    source: plaintext.source,
                    kind: plaintext.kind,
                    plaintextPayloadJSON: try Self.payloadJSONString(plaintext.payload),
                    serverCreatedAtMs: row.createdAtMs,
                    eventTsMs: plaintext.eventTsMs,
                    receivedAtMs: receivedAtMs
                )

                // I4 Stage 6 review fix — batch UPSERTs into a single
                // write transaction (was per-row).
                batchedRows.append(mirrorRow)
            } catch {
                logger.error("mirror decode failed event=\(row.eventID, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        if !batchedRows.isEmpty {
            try database.writeSQL { rawDB in
                for r in batchedRows {
                    try TeamEventMirrorStore.upsert(r, in: rawDB)
                }
            }
            upserted = batchedRows.count
        }
        return MirrorTickResult(
            fetchedCount: rows.count, decodedCount: decoded, upsertedCount: upserted
        )
    }

    /// Realtime push handler — UPSERTs a single pre-decoded `TeamEventMirrorRow`
    /// received from a Supabase Realtime POSTGRES_CHANGES event.
    ///
    /// The row arrives already decrypted and validated by the Realtime dispatch
    /// path. C2/C3 trust gates (senderPubkeyHex + workspaceID) are enforced by
    /// the caller (LeafRealtimeService) before routing here; the service mirrors
    /// the same batch-UPSERT pattern as `tick` but for a single row.
    ///
    /// Idempotent: calling with the same (workspaceID, eventID) twice UPSERTs
    /// without error (matches `TeamEventMirrorStore.upsert` ON CONFLICT DO UPDATE).
    public func absorbRealtimePush(_ row: TeamEventMirrorRow) throws {
        try database.writeSQL { rawDB in
            try TeamEventMirrorStore.upsert(row, in: rawDB)
        }
    }

    // MARK: - Internals

    static func keyIDDataToUUIDString(_ data: Data) -> String {
        guard data.count == 16 else { return "" }
        let bytes = Array(data)
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return uuid.uuidString.lowercased()
    }

    static func payloadJSONString(_ payload: TeamEventPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(payload)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

public actor TeamEventMirrorRetentionPruner {

    public static let defaultRetentionDays: Int = 90

    private let database: LeafCore.Database
    private let retentionDays: Int
    private let now: @Sendable () -> Date
    private let logger: Logger

    public init(
        database: LeafCore.Database,
        retentionDays: Int = defaultRetentionDays,
        now: @escaping @Sendable () -> Date = { Date() },
        logger: Logger = Logger(subsystem: "tech.gundem.leaf.core", category: "team-event-mirror-pruner")
    ) {
        self.database = database
        self.retentionDays = retentionDays
        self.now = now
        self.logger = logger
    }

    /// Delete mirror rows where server_created_at_ms < now - retentionDays*86400000.
    /// Returns count of rows removed.
    @discardableResult
    public func prune() throws -> Int {
        let nowMs = Int64(now().timeIntervalSince1970 * 1000)
        let cutoffMs = nowMs - Int64(retentionDays) * 86_400_000
        let removed = try database.deleteTeamEventMirrorOlderThan(cutoffMs: cutoffMs)
        if removed > 0 {
            logger.info("mirror retention prune removed=\(removed, privacy: .public)")
        }
        return removed
    }
}
