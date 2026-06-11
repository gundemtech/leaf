import Foundation
import LeafCore
import LeafMCPProtocol

/// Track B2 — `leaf_search`: the landing-page `leaf.search("payment service")`
/// promise, literal. One call returns the same composed result rows the
/// in-app Search tab renders: decisions first (with the AUTHOR / CHANNEL /
/// COMMIT / TICKET / PR detail grid), then open questions / blockers, then
/// substance event matches. Default window: last 90 days.
struct LeafSearchTool: ToolExecutor {
    let dbURL: URL
    let dbConfig: DatabaseConfig
    let dbEncryption: EncryptionOptions?
    let detectorMoat: DetectorMoat

    private static let defaultWindowDays: Int64 = 90

    static let definition = ToolDefinition(
        name: D3ToolSchemas.ToolName.search,
        description: """
            Search everything Leaf remembers — decisions (ranked first, with \
            author/channel/commit/ticket/PR attribution), open questions, \
            blockers and raw event matches. \
            ADR-010: bodies surface as 500-char excerpts only.
            """,
        inputSchema: AnyCodable(D3ToolSchemas.search())
    )

    func execute(arguments: AnyCodable?) async throws -> ToolCallResult {
        switch D3ToolParams.decodeSearch(arguments: arguments?.value) {
        case .error(let msg):
            throw MCPProtocolError.invalidParams(msg)
        case .ok(let (query, period, limit)):
            guard FileManager.default.fileExists(atPath: dbURL.path) else {
                return ToolCallResult(
                    content: [.text(TextContent(
                        text: "Leaf database not found at \(dbURL.path). Enable 'Background collection' in Settings first."
                    ))],
                    isError: true
                )
            }
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let resolvedPeriod = period ?? PeriodSpec(
                startMs: nowMs - Self.defaultWindowDays * 86_400_000,
                endMs: nowMs
            )
            let engine = QueryEngine(
                dbURL: dbURL,
                dbConfig: dbConfig,
                dbEncryption: dbEncryption,
                detectorMoat: detectorMoat
            )
            let response = try engine.search(query: query, period: resolvedPeriod, limit: limit)
            return try ToolResponseBuilder.versionedJSONResult(
                D3ResponseEncoder.toDict(response)
            )
        }
    }
}
