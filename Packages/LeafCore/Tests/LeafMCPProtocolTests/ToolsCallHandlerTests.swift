import XCTest

@testable import LeafMCPProtocol

final class ToolsCallHandlerTests: XCTestCase {
    func testUnknownToolThrowsInvalidParams() async throws {
        let h = ToolsCallHandler(registry: [:])
        let params: [String: Any] = ["name": "no_such_tool", "arguments": [:]]
        let any = try JSONDecoder().decode(
            AnyCodable.self,
            from: JSONSerialization.data(withJSONObject: params)
        )
        do {
            _ = try await h.handle(params: any)
            XCTFail("expected MCPProtocolError.invalidParams")
        } catch let e as MCPProtocolError {
            if case .invalidParams(let msg) = e {
                XCTAssertTrue(msg.contains("no_such_tool"), msg)
            } else {
                XCTFail("expected .invalidParams, got \(e)")
            }
        }
    }

    func testKnownToolIsInvokedWithArguments() async throws {
        actor CapturingTool: ToolExecutor {
            var capturedArgs: AnyCodable?
            func execute(arguments: AnyCodable?) async throws -> ToolCallResult {
                capturedArgs = arguments
                return ToolCallResult(
                    content: [.text(TextContent(text: "ok"))],
                    isError: false
                )
            }
        }
        let tool = CapturingTool()
        let h = ToolsCallHandler(registry: ["do_thing": tool])
        let params: [String: Any] = ["name": "do_thing", "arguments": ["x": 1]]
        let any = try JSONDecoder().decode(
            AnyCodable.self,
            from: JSONSerialization.data(withJSONObject: params)
        )
        let result = try await h.handle(params: any)
        let data = try JSONEncoder().encode(result)
        let s = String(data: data, encoding: .utf8)!
        XCTAssertTrue(s.contains(#""text":"ok""#), s)
    }
}
