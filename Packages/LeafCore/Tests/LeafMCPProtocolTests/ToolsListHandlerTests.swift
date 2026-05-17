import XCTest

@testable import LeafMCPProtocol

// swiftlint:disable force_unwrapping
// Reason: test fixtures rely on force-unwrap for setup convenience —
// URL literals, HTTPURLResponse construction, decoded JSON, post-`try`
// DB reads where nil ⇒ broken test, not production semantic.

final class ToolsListHandlerTests: XCTestCase {
    func testReturnsRegisteredToolsAsToolsListResult() async throws {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "period": ["type": "string", "enum": ["today", "yesterday", "last_7_days"]]
            ],
            "additionalProperties": false,
        ]
        let def = ToolDefinition(
            name: "get_timeline",
            description: "Top apps by time",
            inputSchema: AnyCodable(schema)
        )
        let h = ToolsListHandler(tools: [def])

        let result = try await h.handle(params: nil)
        let data = try JSONEncoder().encode(result)
        let s = String(data: data, encoding: .utf8)!
        XCTAssertTrue(s.contains(#""tools""#), s)
        XCTAssertTrue(s.contains(#""get_timeline""#), s)
        XCTAssertTrue(s.contains(#""additionalProperties":false"#), s)
    }
}
// swiftlint:enable force_unwrapping
