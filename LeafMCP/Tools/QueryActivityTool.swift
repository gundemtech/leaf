import Foundation
import LeafCore
import LeafMCPProtocol

/// Phase Track-1 D3 — `leaf_query_activity` MCP tool.
///
/// Thin wrapper over `QueryEngine.queryActivity(period:filter:)`. Heavy lifting
/// (FTS+links+detectors composition, byte-budget trim) lives in LeafCore so it is
/// testable via SPM (LeafMCP — Xcode target, not part of `swift test`).
///
/// Schema and param-decoding helpers also live in LeafCore (`D3ToolSchemas` /
/// `D3ToolParams`) so they can be exercised by SPM tests without xcodebuild.
struct QueryActivityTool: ToolExecutor {
    let dbURL: URL
    let dbConfig: DatabaseConfig
    let dbEncryption: EncryptionOptions?
    let detectorMoat: DetectorMoat

    static let definition = ToolDefinition(
        name: D3ToolSchemas.ToolName.queryActivity,
        description: """
            Composes timeline + decisions + open questions + blockers + links \
            + absence flags for a period, optionally filtered by FTS keyword. \
            Returns structured JSON; AI client narrates. \
            ADR-010: bodies surface only as 500-char excerpts on-device, never via team relay.
            """,
        inputSchema: AnyCodable(D3ToolSchemas.queryActivity())
    )

    func execute(arguments: AnyCodable?) async throws -> ToolCallResult {
        // Strict validation — period required. Missing/invalid → JSON-RPC error
        // (mirror `get_timeline` shape; clients must explicitly scope window).
        switch D3ToolParams.decodeQueryActivity(arguments: arguments?.value) {
        case .error(let msg):
            throw MCPProtocolError.invalidParams(msg)
        case .ok(let (period, filter)):
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
            let response = try engine.queryActivity(period: period, filter: filter)
            return try ToolResponseBuilder.versionedJSONResult(
                D3ResponseEncoder.toDict(response)
            )
        }
    }
}
