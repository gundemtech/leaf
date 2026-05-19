import Foundation
import LeafCore
import LeafMCPProtocol

/// Track 5 / S8 / T7 — `leaf_query_team` MCP tool.
///
/// Closes UC-T5-2 AI half: Cursor / Claude Code can ask "what has <teammate>
/// been working on" via a structured Codable JSON timeline derived from the
/// local mirror of auto-shared events (`team_events_mirror`).
///
/// Thin wrapper over `TeamTimelineQueryService` (LeafCore actor) + the
/// `QueryTeamPayloadFilter` second-layer allowlist (LeafCore static). Heavy
/// lifting + tests live in LeafCore — LeafMCP is an Xcode target outside
/// `swift test` (see GetCurrentPresenceTool.swift for the same pattern).
///
/// Privacy invariants (spec §C5):
/// - Member resolution local-only (service enforces — never queries Supabase).
/// - sender_pubkey ≠ self filter (service returns empty result).
/// - Second-layer per-source allowlist (this tool's `execute(...)` step
///   `QueryTeamPayloadFilter.filter(_:)`) drops banned keys regardless of
///   what the mirror row contained.
struct QueryTeamTool: ToolExecutor {
    let queryService: TeamTimelineQueryService

    static let definition: ToolDefinition = {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "member": [
                    "type": "string",
                    "description": "Teammate identifier — either a 64-char X25519 pubkey hex OR a display_name from the active workspace. Display names are resolved case-insensitively against the local team_members table; ambiguous names raise an error."
                ],
                "since": [
                    "type": "string",
                    "format": "date-time",
                    "description": "Lower bound (ISO-8601 timestamp, inclusive). Default: 24 hours before now."
                ],
                "until": [
                    "type": "string",
                    "format": "date-time",
                    "description": "Upper bound (ISO-8601 timestamp, inclusive). Default: now."
                ],
                "kinds": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "Optional filter on source_kind (e.g. 'git_commits', 'linear_issues', 'detected_blockers'). Empty or omitted → all sources."
                ],
                "limit": [
                    "type": "integer",
                    "description": "Maximum events to return. Default 100, hard cap 500. Requests above 500 are clamped + flagged via `truncated: true`."
                ]
            ],
            "required": ["member"],
            "additionalProperties": false
        ]
        return ToolDefinition(
            name: "leaf_query_team",
            description: """
                Returns a structured timeline of auto-shared team events from a single \
                teammate over a time window. Reads the local on-device mirror of \
                broadcast events (Track 5 / S5 substrate) — NEVER queries Supabase \
                directly. Member resolution is local-only: pubkey hex OR display_name \
                from the active workspace. Querying your own pubkey returns 0 events \
                (UC-T5-2 is a teammate-introspection tool). \
                ADR-010: payloads are filtered through a per-source allowlist before \
                surface; no message bodies, no commit message bodies, no AI prompts.
                """,
            inputSchema: AnyCodable(schema)
        )
    }()

    func execute(arguments: AnyCodable?) async throws -> ToolCallResult {
        // Parse arguments.
        let args = (arguments?.value as? [String: Any]) ?? [:]
        guard let memberRaw = args["member"] as? String, !memberRaw.isEmpty else {
            throw MCPProtocolError.invalidParams(
                "leaf_query_team requires 'member' argument (pubkey hex or display_name)"
            )
        }

        let since = Self.parseISO8601(args["since"])
        let until = Self.parseISO8601(args["until"])
        let kinds = args["kinds"] as? [String]
        let limit: Int? = {
            if let i = args["limit"] as? Int { return i }
            if let d = args["limit"] as? Double { return Int(d) }
            return nil
        }()

        // Invoke service.
        let result: TeamTimelineQueryService.TeamTimelineResult
        do {
            result = try await queryService.query(
                member: memberRaw,
                since: since,
                until: until,
                kinds: kinds,
                limit: limit
            )
        } catch let e as TeamTimelineQueryService.QueryError {
            // Business-logic error → MCP isError surface (tool spec: "Tool
            // execution failed" path; ToolsCallHandler maps this).
            return ToolCallResult(
                content: [.text(TextContent(text: Self.humanMessage(for: e)))],
                isError: true
            )
        }

        // Apply second-layer allowlist filter (defence-in-depth per spec §C5).
        let filtered = QueryTeamPayloadFilter.filter(result)

        // Encode via Codable → JSON → wrap in versioned envelope.
        return try ToolResponseBuilder.versionedJSONResult(
            Self.encodeResult(filtered)
        )
    }

    // MARK: - Helpers

    /// ISO-8601 → Date. Returns nil on parse failure (caller treats as
    /// "use default window bound").
    static func parseISO8601(_ value: Any?) -> Date? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        // Try fractional seconds first (matches Supabase timestamptz shape +
        // SupabaseClient ISO formatter elsewhere in the codebase).
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: s) { return d }
        let noFrac = ISO8601DateFormatter()
        noFrac.formatOptions = [.withInternetDateTime]
        return noFrac.date(from: s)
    }

    /// QueryError → human-readable surface text. Mirrors the
    /// DirectMessageSendReader.humanMessage(for:) discipline (T7 spec §C5 +
    /// S4 review I9 pattern).
    static func humanMessage(for error: TeamTimelineQueryService.QueryError) -> String {
        switch error {
        case .ambiguousMemberName(let input):
            return "Ambiguous member name '\(input)' — multiple active members match. Please use the pubkey hex instead."
        case .memberNotFound(let input):
            return "No active member matches '\(input)' in the active workspace."
        case .workspaceUnknown:
            return "No active workspace on this device. Join or create a workspace in Leaf first."
        case .selfPubkeyUnknown:
            return "Local identity not yet bootstrapped. Retry after Leaf finishes onboarding."
        }
    }

    /// Encode the Codable result via JSONEncoder, then re-parse into the
    /// JSONSerialization dict shape that `ToolResponseBuilder.versionedJSONResult`
    /// accepts. Round-tripping ensures the AnyJSONValue payload values
    /// serialize as native JSON types (not Codable container shapes).
    static func encodeResult(
        _ result: TeamTimelineQueryService.TeamTimelineResult
    ) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(result)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Defensive — encoder always produces an object for our struct.
            return [:]
        }
        return dict
    }
}
