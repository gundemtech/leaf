import Foundation
import LeafCore
import LeafMCPProtocol

/// Phase Track-1 D3 — `leaf_current_work` MCP tool.
///
/// Thin wrapper around `QueryEngine.currentWork(nowMs:)`. The heavy lifting
/// (latest-event projections per signal type, where_stopped freshness gate)
/// lives in LeafCore. Schema / param decoders shared via `D3ToolSchemas` / `D3ToolParams`.
struct CurrentWorkTool: ToolExecutor {
    let dbURL: URL
    let dbConfig: DatabaseConfig
    let dbEncryption: EncryptionOptions?
    let detectorMoat: DetectorMoat

    static let definition = ToolDefinition(
        name: D3ToolSchemas.ToolName.currentWork,
        description: """
            Returns "what the user is working on right now" — current app/branch/file, \
            in-progress Linear ticket, last commit, currently open questions and blockers, \
            plus an optional `whereStopped` excerpt (only when generated within the last 24h). \
            ADR-010: bodies surface only as 500-char excerpts on-device.
            """,
        inputSchema: AnyCodable(D3ToolSchemas.currentWork())
    )

    func execute(arguments: AnyCodable?) async throws -> ToolCallResult {
        let nowMs: Int64
        switch D3ToolParams.decodeCurrentWork(arguments: arguments?.value) {
        case .error(let msg):
            throw MCPProtocolError.invalidParams(msg)
        case .ok(let override):
            nowMs = override ?? Int64(Date().timeIntervalSince1970 * 1000)
        }

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
        let response = try engine.currentWork(nowMs: nowMs)
        return try ToolResponseBuilder.versionedJSONResult(
            D3ResponseEncoder.toDict(response)
        )
    }
}
