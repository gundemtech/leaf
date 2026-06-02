import Foundation
import LeafCore
import LeafMCPProtocol

/// MCP tool: return the AI collaboration breakdown for a period (today / yesterday /
/// last_7_days). Reads the same encrypted DB as the MenuBar app — single source of truth.
///
/// Output payload (versioned `version: 1` via `ToolResponseBuilder`):
///   - `period`, `from`, `to` — the window
///   - `aiRatio` — 0..1, share of AI-active minutes out of the union with attention
///   - `aiActiveSeconds`, `totalActiveSeconds` — for human-readable formatting
///   - `sessionCount` — distinct Claude Code sessions in the window
///   - `topTools[]` — `{name, count}`, top-5 by tool_use count
///   - `topProjects[]` — `{cwd, aiActiveSeconds}`, top-5 by AI-active time
struct GetAiActivityTool: ToolExecutor {
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
                ]
            ],
            "additionalProperties": false
        ]
        return ToolDefinition(
            name: "get_ai_activity",
            description: "Return AI collaboration breakdown (Claude Code) for the given period — ratio, active seconds, session count, top tools, top projects. Metadata only — prompt/response content never leaves the device.",
            inputSchema: AnyCodable(schema)
        )
    }()

    func execute(arguments: AnyCodable?) async throws -> ToolCallResult {
        let period: TimelinePeriod
        if let dict = arguments?.value as? [String: Any],
           let raw = dict["period"] as? String {
            guard let p = TimelinePeriod(rawValue: raw) else {
                throw MCPProtocolError.invalidParams(
                    "period must be one of: today, yesterday, last_7_days"
                )
            }
            period = p
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
        let insights = DerivedInsightsFactory.make(database: database)
        let interval = period.interval()
        let breakdown = try insights.aiActivityBreakdown(period: interval)

        let iso = ISO8601DateFormatter()
        let payload: [String: Any] = [
            "period": period.rawValue,
            "from": iso.string(from: interval.start),
            "to": iso.string(from: interval.end),
            "aiRatio": breakdown.ratio,
            "aiActiveSeconds": Int(breakdown.aiActiveSeconds),
            "totalActiveSeconds": Int(breakdown.totalActiveSeconds),
            "sessionCount": breakdown.sessionCount,
            "topTools": breakdown.topTools.map { entry -> [String: Any] in
                ["name": entry.name, "count": entry.count]
            },
            "topProjects": breakdown.topProjects.map { entry -> [String: Any] in
                ["cwd": entry.cwd, "aiActiveSeconds": Int(entry.aiActiveSeconds)]
            }
        ]
        return try ToolResponseBuilder.versionedJSONResult(payload)
    }
}
