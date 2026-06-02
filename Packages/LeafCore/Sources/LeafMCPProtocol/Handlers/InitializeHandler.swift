import Foundation

public struct InitializeHandler: MethodHandler {
    public let method = "initialize"

    public init() {}

    public func handle(params: AnyCodable?) async throws -> AnyCodable {
        // Spec: server SHOULD echo client's protocolVersion if supports, else
        // respond with latest supported. MVP always returns latest — see
        // plan's "Known limitations" (version negotiation — v1.1 track).
        let result = InitializeResult(
            protocolVersion: MCPConstants.protocolVersion,
            capabilities: ServerCapabilities(tools: ToolsCapability(listChanged: false)),
            serverInfo: ServerInfo(
                name: MCPConstants.serverName,
                version: MCPConstants.serverVersion
            )
        )
        // Double-hop encode/decode — InitializeResult → JSON → AnyCodable.
        // Called once per MCP session, overhead is negligible.
        let data = try JSONEncoder().encode(result)
        return try JSONDecoder().decode(AnyCodable.self, from: data)
    }
}
