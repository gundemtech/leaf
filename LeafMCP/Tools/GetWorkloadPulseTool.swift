import Foundation
import LeafCore
import LeafMCPProtocol

/// Phase 4.7.B-16 — `get_workload_pulse` MCP tool.
///
/// Тонкая обёртка над `PresenceInsights.workloadPulse(database:period:)`.
/// Heavy lifting (DB read, presence_state merge, events aggregates) живёт
/// в LeafCore чтобы быть testable через SPM (LeafMCP — Xcode target, в
/// `swift test` не входит).
///
/// Period — optional argument; невалидный или отсутствующий → defaults to
/// `today` (mirror к B-15 `get_current_presence` permissive shape — tool
/// не должен падать, если AI-клиент послал `period:"unknown"`).
struct GetWorkloadPulseTool: ToolExecutor {
    let dbURL: URL
    let dbConfig: DatabaseConfig
    let dbEncryption: EncryptionOptions?

    static let definition: ToolDefinition = {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "period": [
                    "type": "string",
                    "enum": ["today", "this_week", "last_24h"],
                    "description":
                        "Aggregation window for events-based counts (default: today). presence_state rows are always live.",
                ]
            ],
            "additionalProperties": false,
        ]
        return ToolDefinition(
            name: "get_workload_pulse",
            description: """
                Returns aggregated workload pulse across GitHub / Linear / Slack — \
                "сколько на тарелке прямо сейчас". Combines live `presence_state` \
                rows (PR queue size / cycle progress / DND / native presence) с \
                recent events aggregates (mention counts, file uploads, in-progress \
                CI runs). Period влияет только на events-aggregates. \
                ADR-010: no message bodies, no PR/issue titles, no Slack message text.
                """,
            inputSchema: AnyCodable(schema)
        )
    }()

    func execute(arguments: AnyCodable?) async throws -> ToolCallResult {
        // Permissive parse: невалидный/отсутствующий period → today. Не throw'ить
        // — plan testExecute_InvalidPeriod_DefaultsToToday verifies этот invariant.
        let period: PresenceInsights.WorkloadPulsePeriod
        if let dict = arguments?.value as? [String: Any],
            let raw = dict["period"] as? String,
            let parsed = PresenceInsights.WorkloadPulsePeriod(rawValue: raw)
        {
            period = parsed
        } else {
            period = .today
        }

        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            return ToolCallResult(
                content: [
                    .text(
                        TextContent(
                            text:
                                "Leaf database not found at \(dbURL.path). Enable 'Background collection' in Settings first."
                        ))
                ],
                isError: true
            )
        }

        let database = try Database.openForRead(at: dbURL, config: dbConfig, encryption: dbEncryption)
        let payload = try PresenceInsights.workloadPulse(database: database, period: period)
        return try ToolResponseBuilder.versionedJSONResult(payload)
    }
}
