import XCTest

@testable import LeafMCPProtocol

final class MCPTypesTests: XCTestCase {
    func testInitializeResultCarriesCurrentProtocolVersion() throws {
        let r = InitializeResult(
            protocolVersion: MCPConstants.protocolVersion,
            capabilities: ServerCapabilities(tools: ToolsCapability(listChanged: false)),
            serverInfo: ServerInfo(name: "leaf", version: "0.1.0")
        )
        let data = try JSONEncoder().encode(r)
        let s = String(data: data, encoding: .utf8)!
        XCTAssertTrue(s.contains(#""protocolVersion":"2025-11-25""#), s)
        XCTAssertTrue(s.contains(#""listChanged":false"#), s)
        XCTAssertTrue(s.contains(#""name":"leaf""#), s)
    }

    func testToolDefinitionEncodesJSONSchemaInputSchema() throws {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "period": ["type": "string", "enum": ["today", "yesterday", "last_7_days"]]
            ],
            "additionalProperties": false,
        ]
        let tool = ToolDefinition(
            name: "get_timeline",
            description: "Top apps for a period",
            inputSchema: AnyCodable(schema)
        )
        let data = try JSONEncoder().encode(tool)
        let s = String(data: data, encoding: .utf8)!
        XCTAssertTrue(s.contains(#""name":"get_timeline""#), s)
        XCTAssertTrue(s.contains(#""additionalProperties":false"#), s)
    }

    func testToolCallResultTextContentRoundTrip() throws {
        let result = ToolCallResult(
            content: [.text(TextContent(text: "hello"))],
            isError: false
        )
        let data = try JSONEncoder().encode(result)
        let back = try JSONDecoder().decode(ToolCallResult.self, from: data)
        XCTAssertFalse(back.isError)
        XCTAssertEqual(back.content.count, 1)
        if case .text(let t) = back.content[0] {
            XCTAssertEqual(t.text, "hello")
            XCTAssertEqual(t.type, "text")
        } else {
            XCTFail("expected .text content")
        }
    }
}
