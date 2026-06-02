import Foundation

public protocol ToolExecutor: Sendable {
    func execute(arguments: AnyCodable?) async throws -> ToolCallResult
}

public struct ToolsCallHandler: MethodHandler {
    public let method = "tools/call"
    public let registry: [String: any ToolExecutor]

    public init(registry: [String: any ToolExecutor]) {
        self.registry = registry
    }

    public func handle(params: AnyCodable?) async throws -> AnyCodable {
        guard let raw = params?.value as? [String: Any],
              let name = raw["name"] as? String else {
            throw MCPProtocolError.invalidParams(
                "tools/call requires {name: string, arguments?: object}"
            )
        }
        guard let tool = registry[name] else {
            throw MCPProtocolError.invalidParams("Unknown tool: \(name)")
        }

        let argsValue = raw["arguments"]
        // .fragmentsAllowed — if the client sent "arguments" as a non-object
        // (String/Number/null) we don't fail in JSONSerialization; the tool itself
        // decides whether to accept or reject.
        let argsData = try JSONSerialization.data(
            withJSONObject: argsValue ?? NSNull(),
            options: [.fragmentsAllowed]
        )
        let argsAny = try JSONDecoder().decode(AnyCodable.self, from: argsData)
        let args: AnyCodable? = argsAny.value is NSNull ? nil : argsAny

        do {
            let callResult = try await tool.execute(arguments: args)
            let data = try JSONEncoder().encode(callResult)
            return try JSONDecoder().decode(AnyCodable.self, from: data)
        } catch let e as MCPProtocolError {
            // Protocol-level errors (invalid arguments shape) → JSON-RPC error.
            throw e
        } catch {
            // Business logic errors → result.isError: true (MCP spec).
            let errResult = ToolCallResult(
                content: [.text(TextContent(text: "Tool execution failed: \(error)"))],
                isError: true
            )
            let data = try JSONEncoder().encode(errResult)
            return try JSONDecoder().decode(AnyCodable.self, from: data)
        }
    }
}
