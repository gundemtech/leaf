import Foundation
import LeafCore
import LeafMCPProtocol

/// Phase 4.7.B-17 — `get_review_activity` MCP tool.
///
/// Thin wrapper over `ReviewActivityInsights.reviewActivity(database:period:repo:)`.
/// Heavy lifting (DB scan, GROUP BY event_kind, by_repo + linked_prs aggregation)
/// lives in LeafCore so it's testable via SPM (LeafMCP — Xcode target,
/// not included in `swift test`).
///
/// `period` — optional argument, mirroring other tools (today / yesterday /
/// last_7_days). Invalid raw → invalidParams (strict — mirrors
/// `get_timeline`, unlike the B-16 permissive shape for `workload_pulse`).
/// `repo` — optional "owner/name" filter; if present and non-empty →
/// limit aggregation to that repo.
struct GetReviewActivityTool: ToolExecutor {
    let dbURL: URL
    let dbConfig: DatabaseConfig
    let dbEncryption: EncryptionOptions?

    static let definition: ToolDefinition = {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "period": [
                    "type": "string",
                    "enum": ["today", "yesterday", "last_7_days"],
                    "description": "Time window (default: today)"
                ],
                "repo": [
                    "type": "string",
                    "description": "Optional 'owner/name' filter — limit aggregation to single repo."
                ]
            ],
            "additionalProperties": false
        ]
        return ToolDefinition(
            name: "get_review_activity",
            description: """
                Returns aggregated GitHub review activity across pr_review_* event_kinds — \
                reviews submitted, review comments authored, and (Track C) review threads \
                resolved. GROUP BY repo + linked PR/Linear pairs derived from \
                Phase 4.7.A `linked_linear_id` field. \
                ADR-010: no PR titles, no review-comment bodies, no diff text.
                """,
            inputSchema: AnyCodable(schema)
        )
    }()

    func execute(arguments: AnyCodable?) async throws -> ToolCallResult {
        let period: ReviewActivityInsights.ReviewActivityPeriod
        var repoFilter: String? = nil
        if let dict = arguments?.value as? [String: Any] {
            if let raw = dict["period"] as? String {
                guard let p = ReviewActivityInsights.ReviewActivityPeriod(rawValue: raw) else {
                    throw MCPProtocolError.invalidParams(
                        "period must be one of: today, yesterday, last_7_days"
                    )
                }
                period = p
            } else {
                period = .today
            }
            if let r = dict["repo"] as? String, !r.isEmpty {
                repoFilter = r
            }
        } else {
            period = .today
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
        let payload = try ReviewActivityInsights.reviewActivity(
            database: database,
            period: period,
            repo: repoFilter
        )
        return try ToolResponseBuilder.versionedJSONResult(payload)
    }
}
