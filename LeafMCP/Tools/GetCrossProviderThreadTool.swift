import Foundation
import LeafCore
import LeafMCPProtocol

/// Phase 4.7.B-18 — `get_cross_provider_thread` MCP tool.
///
/// A thin wrapper over `CrossProviderInsights.crossProviderThread(database:linearIssueID:)`.
/// Heavy lifting (UNION SQL, payload whitelist projection) lives in LeafCore
/// so it stays testable via SPM (LeafMCP is an Xcode target, not part of `swift test`).
///
/// `linear_issue_id` — required argument. If absent or not a string →
/// returns `ToolCallResult.isError = true` (per plan literal — does NOT throw
/// MCPProtocolError). This is a distinct shape from `get_timeline` (which strict-throws)
/// and from `get_workload_pulse` (permissive default) — we follow the plan for each
/// individual tool.
struct GetCrossProviderThreadTool: ToolExecutor {
    let dbURL: URL
    let dbConfig: DatabaseConfig
    let dbEncryption: EncryptionOptions?

    static let definition: ToolDefinition = {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "linear_issue_id": [
                    "type": "string",
                    "description": "Linear issue ID (e.g. 'LEAF-456'). Required."
                ]
            ],
            "required": ["linear_issue_id"],
            "additionalProperties": false
        ]
        return ToolDefinition(
            name: "get_cross_provider_thread",
            description: """
                Returns chronological cross-provider timeline of activity referencing a \
                Linear issue ID — Linear issue updates plus GitHub commits/PRs whose \
                payload carries `linked_linear_id` (Phase 4.7.A LinearIDExtractor). \
                Slack events deferred to Phase 4.8. \
                ADR-010: payload projection whitelist — no titles, commit message bodies, \
                or PR descriptions surfaced.
                """,
            inputSchema: AnyCodable(schema)
        )
    }()

    func execute(arguments: AnyCodable?) async throws -> ToolCallResult {
        // Required arg validation. Plan literal: missing arg → ToolCallResult.isError=true.
        guard
            let dict = arguments?.value as? [String: Any],
            let issueID = dict["linear_issue_id"] as? String,
            !issueID.isEmpty
        else {
            return ToolCallResult(
                content: [.text(TextContent(
                    text: "Missing required argument 'linear_issue_id' (string, e.g. 'LEAF-456')."
                ))],
                isError: true
            )
        }

        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            return ToolCallResult(
                content: [.text(TextContent(
                    text: "Leaf database not found at \(dbURL.path). Enable 'Background collection' in Settings first."
                ))],
                isError: true
            )
        }

        let database = try Database.openForRead(at: dbURL, config: dbConfig, encryption: dbEncryption)
        let payload = try CrossProviderInsights.crossProviderThread(
            database: database,
            linearIssueID: issueID
        )
        return try ToolResponseBuilder.versionedJSONResult(payload)
    }
}
