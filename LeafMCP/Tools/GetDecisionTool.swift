import Foundation
import LeafCore
import LeafMCPProtocol

/// Phase Track-1 D3 — `leaf_get_decision` MCP tool.
///
/// A thin wrapper over `QueryEngine.getDecision(topic:period:)`. Heavy lifting
/// (FTS rank by confidence + recency, originating-event projection, outbound links)
/// lives in LeafCore. Schema / param decoders shared via `D3ToolSchemas` / `D3ToolParams`.
struct GetDecisionTool: ToolExecutor {
    let dbURL: URL
    let dbConfig: DatabaseConfig
    let dbEncryption: EncryptionOptions?
    let detectorMoat: DetectorMoat

    static let definition = ToolDefinition(
        name: D3ToolSchemas.ToolName.getDecision,
        description: """
            Returns the highest-confidence decision(s) matching the topic — \
            originating event projection plus outbound links \
            (Linear ticket / GitHub PR / Slack thread). \
            Returns null `decision` when no FTS candidate matches. \
            ADR-010: reasoning surfaces as a 500-char excerpt only.
            """,
        inputSchema: AnyCodable(D3ToolSchemas.getDecision())
    )

    func execute(arguments: AnyCodable?) async throws -> ToolCallResult {
        switch D3ToolParams.decodeGetDecision(arguments: arguments?.value) {
        case .error(let msg):
            throw MCPProtocolError.invalidParams(msg)
        case .ok(let (topic, period, limit)):
            guard FileManager.default.fileExists(atPath: dbURL.path) else {
                return ToolCallResult(
                    content: [.text(TextContent(
                        text: "Leaf database not found at \(dbURL.path). Enable 'Background collection' in Settings first."
                    ))],
                    isError: true
                )
            }
            let engine = QueryEngine(
                dbURL: dbURL,
                dbConfig: dbConfig,
                dbEncryption: dbEncryption,
                detectorMoat: detectorMoat
            )
            let response = try engine.getDecision(topic: topic, period: period, limit: limit)
            return try ToolResponseBuilder.versionedJSONResult(
                D3ResponseEncoder.toDict(response)
            )
        }
    }
}
