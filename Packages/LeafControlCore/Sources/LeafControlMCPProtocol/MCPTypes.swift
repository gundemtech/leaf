import Foundation

public enum MCPConstants {
    /// Latest MCP protocol version — verified April 2026 against
    /// https://modelcontextprotocol.io/specification/2025-11-25/
    public static let protocolVersion = "2025-11-25"
    public static let serverName = "leafcontrol"
    public static let serverVersion = "0.1.0"
}

public struct InitializeParams: Codable, Sendable {
    public let protocolVersion: String
    public let capabilities: AnyCodable?
    public let clientInfo: ClientInfo?
}

public struct ClientInfo: Codable, Sendable {
    public let name: String
    public let version: String?
}

public struct ServerInfo: Codable, Sendable {
    public let name: String
    public let version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

public struct ToolsCapability: Codable, Sendable {
    public let listChanged: Bool
    public init(listChanged: Bool) { self.listChanged = listChanged }
}

public struct ServerCapabilities: Codable, Sendable {
    public let tools: ToolsCapability?
    public init(tools: ToolsCapability?) { self.tools = tools }
}

public struct InitializeResult: Codable, Sendable {
    public let protocolVersion: String
    public let capabilities: ServerCapabilities
    public let serverInfo: ServerInfo

    public init(protocolVersion: String, capabilities: ServerCapabilities, serverInfo: ServerInfo) {
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.serverInfo = serverInfo
    }
}

public struct ToolDefinition: Codable, Sendable {
    public let name: String
    public let description: String
    public let inputSchema: AnyCodable

    public init(name: String, description: String, inputSchema: AnyCodable) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct ToolsListResult: Codable, Sendable {
    public let tools: [ToolDefinition]
    public init(tools: [ToolDefinition]) { self.tools = tools }
}

public struct ToolCallParams: Codable, Sendable {
    public let name: String
    public let arguments: AnyCodable?
}

public struct TextContent: Codable, Sendable {
    public let type: String
    public let text: String
    public init(text: String) { self.type = "text"; self.text = text }
}

public enum ToolContentItem: Codable, Sendable {
    case text(TextContent)

    private enum CodingKeys: String, CodingKey { case type }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try TextContent(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "Unsupported content type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let t): try t.encode(to: encoder)
        }
    }
}

public struct ToolCallResult: Codable, Sendable {
    public let content: [ToolContentItem]
    public let isError: Bool

    public init(content: [ToolContentItem], isError: Bool) {
        self.content = content
        self.isError = isError
    }
}
