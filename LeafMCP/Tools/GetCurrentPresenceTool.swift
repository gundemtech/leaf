import Foundation
import LeafCore
import LeafMCPProtocol

/// Phase 4.7.B-15 — `get_current_presence` MCP tool.
///
/// Тонкая обёртка над `PresenceInsights.currentSnapshot(database:)`.
/// Heavy lifting (DB read, payload shape) живёт в LeafCore чтобы быть
/// testable через SPM (LeafMCP — Xcode target, в `swift test` не входит).
struct GetCurrentPresenceTool: ToolExecutor {
    let dbURL: URL
    let dbConfig: DatabaseConfig
    let dbEncryption: EncryptionOptions?

    static let definition: ToolDefinition = {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [:] as [String: Any],
            "additionalProperties": false,
        ]
        return ToolDefinition(
            name: "get_current_presence",
            description: """
                Returns the current presence snapshot across GitHub, Linear, Slack — \
                "what is the user doing right now".  Reads materialized view `presence_state`. \
                Includes notifications/PR queue/cycle progress/native Slack presence/DND. \
                ADR-010: no message bodies, no PR/issue titles, no Slack message text.
                """,
            inputSchema: AnyCodable(schema)
        )
    }()

    func execute(arguments: AnyCodable?) async throws -> ToolCallResult {
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
        let payload = try PresenceInsights.currentSnapshot(database: database)
        return try ToolResponseBuilder.versionedJSONResult(payload)
    }
}
