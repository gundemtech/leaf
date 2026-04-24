import Foundation

public struct ToolsListHandler: MethodHandler {
    public let method = "tools/list"
    public let tools: [ToolDefinition]

    public init(tools: [ToolDefinition]) {
        self.tools = tools
    }

    public func handle(params: AnyCodable?) async throws -> AnyCodable {
        let result = ToolsListResult(tools: tools)
        let data = try JSONEncoder().encode(result)
        return try JSONDecoder().decode(AnyCodable.self, from: data)
    }
}
