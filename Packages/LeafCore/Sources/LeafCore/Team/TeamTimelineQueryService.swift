//
//  TeamTimelineQueryService.swift
//  LeafCore
//
//  Track 5 / S8 / T7 — `leaf_query_team(member:)` MCP backend.
//
//  Closes UC-T5-2 AI half: Cursor / Claude Code can ask "what has <teammate>
//  been working on" and receive a structured Codable JSON timeline derived
//  from `team_events_mirror` (the local mirror of auto-shared events landed
//  by Track 5 / S5 broadcast → S5 mirror).
//
//  Critical privacy invariants (spec §C5):
//    1. Member resolution is LOCAL ONLY — NEVER query Supabase to resolve
//       display_name → pubkey. Reads `team_members` for active workspace.
//    2. Sender ≠ self: query returns 0 events when `member == self.pubkey`
//       — UC-T5-2 is a teammate-introspection tool, not a self-mirror tool.
//    3. Bounded result set: default limit 100, max 500.
//    4. Default window: last 24h (since = now - 86400, until = now).
//
//  This service does NOT apply the per-source allowlist filter. That second
//  layer is applied by `QueryTeamTool` (LeafMCP) at MCP-serialization time,
//  mirroring `TeamEventPayloadBuilder.allowedKeys(for:)`. The service trusts
//  the on-device `plaintext_payload_json` already passed through the first
//  layer (broadcast-time filter) before reaching the mirror; the second
//  layer is defence-in-depth against future migrations that might leak
//  legacy rows into the mirror.
//

import Foundation
import GRDB

// MARK: - TeamTimelineQueryService

public actor TeamTimelineQueryService {

    // MARK: - Errors

    public enum QueryError: Swift.Error, Equatable, Sendable {
        /// Two or more active members in the active workspace match the
        /// requested display_name (case-insensitive). Caller must
        /// disambiguate with pubkey hex.
        case ambiguousMemberName(String)

        /// No active member in the active workspace matches the requested
        /// pubkey hex or display_name.
        case memberNotFound(String)

        /// `ActiveWorkspaceStore` returned `nil` — no workspace is active on
        /// this device (cold start before onboarding, or all workspaces
        /// soft-marked left).
        case workspaceUnknown

        /// `selfPubkeyProvider` returned `nil` — local identity not yet
        /// bootstrapped. Cold-start race; caller can retry after a tick.
        case selfPubkeyUnknown
    }

    // MARK: - Result types

    public struct TeamTimelineResult: Codable, Sendable, Equatable {

        public struct Member: Codable, Sendable, Equatable {
            public let pubkey: String
            public let displayName: String

            public init(pubkey: String, displayName: String) {
                self.pubkey = pubkey
                self.displayName = displayName
            }
        }

        public struct Workspace: Codable, Sendable, Equatable {
            public let id: String
            public let name: String

            public init(id: String, name: String) {
                self.id = id
                self.name = name
            }
        }

        public struct Window: Codable, Sendable, Equatable {
            /// Lower bound (inclusive) in epoch milliseconds.
            public let sinceMs: Int64
            /// Upper bound (inclusive) in epoch milliseconds.
            public let untilMs: Int64

            public init(sinceMs: Int64, untilMs: Int64) {
                self.sinceMs = sinceMs
                self.untilMs = untilMs
            }
        }

        public struct Event: Codable, Sendable, Equatable {
            public let eventID: String
            public let kind: String
            public let sourceKind: String
            /// `team_events_mirror.event_ts_ms` — the source event timestamp
            /// (the moment the sender captured it locally).
            public let tsMs: Int64
            /// Raw payload (still subject to MCP allowlist filter at the
            /// `QueryTeamTool` layer). [String: AnyJSONValue] preserves
            /// nested structure for future composite payloads.
            public let payload: [String: AnyJSONValue]

            public init(
                eventID: String,
                kind: String,
                sourceKind: String,
                tsMs: Int64,
                payload: [String: AnyJSONValue]
            ) {
                self.eventID = eventID
                self.kind = kind
                self.sourceKind = sourceKind
                self.tsMs = tsMs
                self.payload = payload
            }
        }

        public let member: Member
        public let workspace: Workspace
        public let window: Window
        public let events: [Event]
        public let totalCount: Int
        /// `true` when the caller-requested limit exceeded `maxLimit` and was
        /// clamped, indicating more results may exist beyond the returned set.
        public let truncated: Bool

        public init(
            member: Member,
            workspace: Workspace,
            window: Window,
            events: [Event],
            totalCount: Int,
            truncated: Bool
        ) {
            self.member = member
            self.workspace = workspace
            self.window = window
            self.events = events
            self.totalCount = totalCount
            self.truncated = truncated
        }
    }

    // MARK: - Constants

    /// Default events returned per query.
    public static let defaultLimit: Int = 100

    /// Hard cap. Larger requests are clamped + reported via `truncated: true`.
    public static let maxLimit: Int = 500

    /// Default lookback window when `since` is nil — 24 hours.
    public static let defaultSinceSeconds: TimeInterval = 86_400

    // MARK: - Provider closures

    public typealias ActiveWorkspaceProvider = @Sendable () async -> String?
    public typealias SelfPubkeyProvider = @Sendable () async -> String?
    public typealias NowProvider = @Sendable () -> Date

    // MARK: - State

    private let database: Database
    private let activeWorkspaceProvider: ActiveWorkspaceProvider
    private let selfPubkeyProvider: SelfPubkeyProvider
    private let now: NowProvider

    // MARK: - Init

    public init(
        database: Database,
        activeWorkspaceProvider: @escaping ActiveWorkspaceProvider,
        selfPubkeyProvider: @escaping SelfPubkeyProvider,
        now: @escaping NowProvider = { Date() }
    ) {
        self.database = database
        self.activeWorkspaceProvider = activeWorkspaceProvider
        self.selfPubkeyProvider = selfPubkeyProvider
        self.now = now
    }

    // MARK: - Public API

    /// Execute a timeline query.
    ///
    /// - Parameters:
    ///   - member: pubkey hex (64 lowercase hex chars) OR display_name. If
    ///             64-hex, treated as pubkey directly. Otherwise resolved
    ///             against active workspace's local `team_members` rows
    ///             (case-insensitive equality; ambiguous → throw).
    ///   - since:  Lower bound inclusive. nil → 24h ago.
    ///   - until:  Upper bound inclusive. nil → now.
    ///   - kinds:  Filter on `source_kind`. nil / empty → all sources.
    ///   - limit:  Max events returned. nil → 100. Clamped to 500 + truncated.
    /// - Returns: `TeamTimelineResult` with events in DESC chronological order.
    /// - Throws:  `QueryError.workspaceUnknown` / `.selfPubkeyUnknown`
    ///            / `.memberNotFound` / `.ambiguousMemberName`, or DB errors.
    public func query(
        member: String,
        since: Date? = nil,
        until: Date? = nil,
        kinds: [String]? = nil,
        limit: Int? = nil
    ) async throws -> TeamTimelineResult {

        // 1. Resolve active workspace (spec §C5: scope is per-workspace —
        // never cross-workspace lookup).
        guard let workspaceID = await activeWorkspaceProvider() else {
            throw QueryError.workspaceUnknown
        }

        // 2. Resolve self pubkey for the sender ≠ self filter.
        guard let selfPubkey = await selfPubkeyProvider() else {
            throw QueryError.selfPubkeyUnknown
        }

        // 3. Load workspace row (for name) + active members (for resolution
        // + display_name lookup).
        let workspaceRow = try database.listWorkspaces(includeLeft: true)
            .first { $0.id == workspaceID }
        guard let workspaceRow else {
            throw QueryError.workspaceUnknown
        }
        let members = try database.readTeamMembers(workspaceID: workspaceID)

        // 4. Member resolution — local only.
        let (memberPubkey, memberDisplayName) = try Self.resolveMember(
            input: member,
            members: members
        )

        // 5. Self-pubkey filter (case-insensitive on the hex string).
        if memberPubkey.lowercased() == selfPubkey.lowercased() {
            // Empty result — UC-T5-2 explicit: don't mirror own activity.
            let nowDate = now()
            let resolvedSinceMs = Int64((since ?? nowDate.addingTimeInterval(-Self.defaultSinceSeconds))
                .timeIntervalSince1970 * 1000)
            let resolvedUntilMs = Int64((until ?? nowDate).timeIntervalSince1970 * 1000)
            return TeamTimelineResult(
                member: .init(pubkey: memberPubkey, displayName: memberDisplayName),
                workspace: .init(id: workspaceID, name: workspaceRow.name),
                window: .init(sinceMs: resolvedSinceMs, untilMs: resolvedUntilMs),
                events: [],
                totalCount: 0,
                truncated: false
            )
        }

        // 6. Resolve window bounds.
        let nowDate = now()
        let sinceDate = since ?? nowDate.addingTimeInterval(-Self.defaultSinceSeconds)
        let untilDate = until ?? nowDate
        let sinceMs = Int64(sinceDate.timeIntervalSince1970 * 1000)
        let untilMs = Int64(untilDate.timeIntervalSince1970 * 1000)

        // 7. Clamp limit. Track if caller exceeded max.
        let requestedLimit = limit ?? Self.defaultLimit
        let effectiveLimit = min(max(requestedLimit, 0), Self.maxLimit)
        let truncated = requestedLimit > Self.maxLimit

        // 8. Normalize kinds filter — empty array treated as nil.
        let kindFilter: [String]? = (kinds?.isEmpty ?? true) ? nil : kinds

        // 9. Execute SELECT.
        let rows: [TeamEventMirrorRow] = try database.readSQL { db in
            try Self.runQuery(
                db: db,
                workspaceID: workspaceID,
                memberPubkey: memberPubkey,
                sinceMs: sinceMs,
                untilMs: untilMs,
                kindFilter: kindFilter,
                limit: effectiveLimit
            )
        }

        // 10. Map rows → Event values, parsing payload JSON.
        let events = rows.map { row -> TeamTimelineResult.Event in
            let payload = Self.parsePayloadJSON(row.plaintextPayloadJSON)
            return TeamTimelineResult.Event(
                eventID: row.eventID,
                kind: row.kind,
                sourceKind: row.source.rawValue,
                tsMs: row.eventTsMs,
                payload: payload
            )
        }

        return TeamTimelineResult(
            member: .init(pubkey: memberPubkey, displayName: memberDisplayName),
            workspace: .init(id: workspaceID, name: workspaceRow.name),
            window: .init(sinceMs: sinceMs, untilMs: untilMs),
            events: events,
            totalCount: events.count,
            truncated: truncated
        )
    }

    // MARK: - Member resolution (LOCAL ONLY — spec §C5)

    /// Returns `(pubkeyHex, displayName)` for the resolved member.
    ///
    /// Resolution rules:
    /// - 64 lowercase hex chars → treat as pubkey; lookup display_name from
    ///   members (fallback to "<unknown>" if not in active list, since the
    ///   teammate may have been removed from this workspace but still has
    ///   historical events in the mirror).
    /// - Otherwise → case-insensitive equality on `display_name`. 0 matches
    ///   → `.memberNotFound`; 2+ → `.ambiguousMemberName`.
    internal static func resolveMember(
        input: String,
        members: [TeamMember]
    ) throws -> (pubkey: String, displayName: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw QueryError.memberNotFound(input)
        }

        // Pubkey hex shape: exactly 64 lowercase hex chars (we lower the
        // input for comparison; canonical storage in team_members.pubkey_hex
        // is lowercase via the existing crypto path).
        let lower = trimmed.lowercased()
        if lower.count == 64,
           lower.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) {
            if let match = members.first(where: { $0.pubkeyHex.lowercased() == lower }) {
                return (match.pubkeyHex, match.displayName)
            }
            // Honor pubkey query even when the member was removed from the
            // active workspace — historical events may still exist in the
            // mirror with this sender_pubkey. UI surface chooses "<unknown>".
            return (lower, "<unknown>")
        }

        // Display-name path — case-insensitive equality.
        let needle = trimmed.lowercased()
        let matches = members.filter { $0.displayName.lowercased() == needle }
        switch matches.count {
        case 0:
            throw QueryError.memberNotFound(input)
        case 1:
            return (matches[0].pubkeyHex, matches[0].displayName)
        default:
            throw QueryError.ambiguousMemberName(input)
        }
    }

    // MARK: - SQL execution

    /// Executes the SELECT against `team_events_mirror`.
    ///
    /// SQL invariants (mirror `TeamFeedQueryService.runQuery` patterns):
    /// - All values are bound via `StatementArguments` — never interpolated.
    /// - The `source_kind IN (...)` clause uses one positional placeholder
    ///   per item; avoids CSV injection.
    /// - Ordering: `event_ts_ms DESC` to surface most-recent activity first.
    ///   `server_created_at_ms` would also work, but `event_ts_ms` better
    ///   matches "when did the teammate do this" semantics for the AI client.
    private static func runQuery(
        db: GRDB.Database,
        workspaceID: String,
        memberPubkey: String,
        sinceMs: Int64,
        untilMs: Int64,
        kindFilter: [String]?,
        limit: Int
    ) throws -> [TeamEventMirrorRow] {
        var sql = """
            SELECT \(Schema.TeamEventsMirror.eventID),
                   \(Schema.TeamEventsMirror.workspaceID),
                   \(Schema.TeamEventsMirror.senderPubkeyHex),
                   \(Schema.TeamEventsMirror.sourceKind),
                   \(Schema.TeamEventsMirror.kind),
                   \(Schema.TeamEventsMirror.plaintextPayloadJSON),
                   \(Schema.TeamEventsMirror.serverCreatedAtMs),
                   \(Schema.TeamEventsMirror.eventTsMs),
                   \(Schema.TeamEventsMirror.receivedAtMs)
            FROM \(Schema.TeamEventsMirror.tableName)
            WHERE \(Schema.TeamEventsMirror.workspaceID) = ?
              AND \(Schema.TeamEventsMirror.senderPubkeyHex) = ?
              AND \(Schema.TeamEventsMirror.eventTsMs) >= ?
              AND \(Schema.TeamEventsMirror.eventTsMs) <= ?
            """

        var args: [DatabaseValueConvertible?] = [
            workspaceID,
            memberPubkey,
            sinceMs,
            untilMs
        ]

        if let kinds = kindFilter, !kinds.isEmpty {
            let placeholders = "(" + kinds.map { _ in "?" }.joined(separator: ", ") + ")"
            sql += "\n              AND \(Schema.TeamEventsMirror.sourceKind) IN \(placeholders)"
            for kind in kinds {
                args.append(kind)
            }
        }

        sql += "\n            ORDER BY \(Schema.TeamEventsMirror.eventTsMs) DESC LIMIT ?"
        args.append(limit)

        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        return rows.compactMap(Self.mapMirrorRow)
    }

    /// Mirrors `TeamEventMirrorStore.mapRow` exactly. Duplicated here because
    /// `mapRow` is `private` and exposing it would widen public surface
    /// unnecessarily; the duplication is intentional + tiny.
    private static func mapMirrorRow(_ row: Row) -> TeamEventMirrorRow? {
        guard
            let eventID = row[Schema.TeamEventsMirror.eventID] as String?,
            let workspaceID = row[Schema.TeamEventsMirror.workspaceID] as String?,
            let senderPubkeyHex = row[Schema.TeamEventsMirror.senderPubkeyHex] as String?,
            let sourceRaw = row[Schema.TeamEventsMirror.sourceKind] as String?,
            let source = ShareSource(rawValue: sourceRaw),
            let kind = row[Schema.TeamEventsMirror.kind] as String?,
            let payloadJSON = row[Schema.TeamEventsMirror.plaintextPayloadJSON] as String?,
            let serverCreatedAtMs = row[Schema.TeamEventsMirror.serverCreatedAtMs] as Int64?,
            let eventTsMs = row[Schema.TeamEventsMirror.eventTsMs] as Int64?,
            let receivedAtMs = row[Schema.TeamEventsMirror.receivedAtMs] as Int64?
        else { return nil }
        return TeamEventMirrorRow(
            eventID: eventID,
            workspaceID: workspaceID,
            senderPubkeyHex: senderPubkeyHex,
            source: source,
            kind: kind,
            plaintextPayloadJSON: payloadJSON,
            serverCreatedAtMs: serverCreatedAtMs,
            eventTsMs: eventTsMs,
            receivedAtMs: receivedAtMs
        )
    }

    // MARK: - Payload parsing

    /// Parses `plaintext_payload_json` into `[String: AnyJSONValue]`.
    ///
    /// The on-device storage shape comes from `TeamEventPlaintext` (a Codable
    /// struct whose `payload.fields` is `[String: String]`). Mirror rows
    /// store the **outer** plaintext JSON. We extract `payload.fields` if
    /// the shape matches; otherwise we fall back to the raw decoded dict
    /// (preserving the structure for AI client narration).
    ///
    /// Returns `[:]` on parse error — never throws, never logs the payload.
    internal static func parsePayloadJSON(_ json: String) -> [String: AnyJSONValue] {
        guard let data = json.data(using: .utf8) else { return [:] }
        guard let any = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        guard let dict = any as? [String: Any] else { return [:] }

        // TeamEventPlaintext-shaped: { "payload": { "fields": { ... } }, ... }.
        // Surface only the inner fields bag — outer keys are envelope metadata
        // that the broadcast layer already binds, and re-surfacing them
        // (sender_pubkey_hex / workspace_id / event_id) would duplicate the
        // top-level Event fields.
        if let payloadDict = dict["payload"] as? [String: Any],
           let fields = payloadDict["fields"] as? [String: Any] {
            return fields.mapValues(AnyJSONValue.init)
        }

        return dict.mapValues(AnyJSONValue.init)
    }
}

// MARK: - AnyJSONValue

/// Type-erased Codable JSON value supporting the full primitive lattice
/// (null / bool / int / double / string) plus recursive arrays and objects.
///
/// Lives alongside `TeamTimelineQueryService` because it's the result-type's
/// payload value type. Distinct from `AnyCodable` in `LeafMCPProtocol`
/// (which exists in a sibling library + is `@unchecked Sendable`); this one
/// is `Sendable`-safe + has structural Equatable for fixture assertions.
public enum AnyJSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([AnyJSONValue])
    case object([String: AnyJSONValue])

    public init(_ value: Any) {
        if value is NSNull {
            self = .null
        } else if let b = value as? Bool {
            self = .bool(b)
        } else if let i = value as? Int {
            self = .int(Int64(i))
        } else if let i64 = value as? Int64 {
            self = .int(i64)
        } else if let d = value as? Double {
            self = .double(d)
        } else if let s = value as? String {
            self = .string(s)
        } else if let arr = value as? [Any] {
            self = .array(arr.map(AnyJSONValue.init))
        } else if let obj = value as? [String: Any] {
            self = .object(obj.mapValues(AnyJSONValue.init))
        } else {
            // Foundation NSNumber bridging can yield ambiguous types; defensive
            // fallback to string description preserves visibility without
            // crashing or dropping the value.
            self = .string(String(describing: value))
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int64.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let arr = try? c.decode([AnyJSONValue].self) { self = .array(arr); return }
        if let obj = try? c.decode([String: AnyJSONValue].self) { self = .object(obj); return }
        throw DecodingError.dataCorruptedError(
            in: c,
            debugDescription: "Unsupported JSON value"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:        try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i):  try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a):  try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}
