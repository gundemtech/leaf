import XCTest
@testable import LeafCore

/// Phase Track-1 D3 — Commit 7. Schema-shape tests for the 3 high-level structured
/// MCP tools. LeafMCP itself has no SPM test target (Xcode-only), so the
/// definitions live in LeafCore (`D3ToolSchemas`) and are exercised here. The
/// LeafMCP tool shells (`QueryActivityTool` / `GetDecisionTool` / `CurrentWorkTool`)
/// reference these same constants — drift is impossible.
final class D3ToolSchemasTests: XCTestCase {

    // MARK: - leaf_query_activity

    func testQueryActivityToolDefinitionMatchesSchema() throws {
        XCTAssertEqual(D3ToolSchemas.ToolName.queryActivity, "leaf_query_activity")

        let schema = D3ToolSchemas.queryActivity()
        XCTAssertEqual(schema["type"] as? String, "object")
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)

        // `period` is required; nested object with required start_ms+end_ms integers.
        let required = schema["required"] as? [String] ?? []
        XCTAssertTrue(required.contains("period"))

        let props = schema["properties"] as? [String: Any] ?? [:]
        let period = props["period"] as? [String: Any] ?? [:]
        XCTAssertEqual(period["type"] as? String, "object")
        let periodProps = period["properties"] as? [String: Any] ?? [:]
        XCTAssertEqual((periodProps["start_ms"] as? [String: Any])?["type"] as? String, "integer")
        XCTAssertEqual((periodProps["end_ms"] as? [String: Any])?["type"] as? String, "integer")
        let periodRequired = period["required"] as? [String] ?? []
        XCTAssertEqual(Set(periodRequired), Set(["start_ms", "end_ms"]))

        // `filter` is optional string.
        let filter = props["filter"] as? [String: Any] ?? [:]
        XCTAssertEqual(filter["type"] as? String, "string")
        XCTAssertFalse(required.contains("filter"))
    }

    // MARK: - leaf_get_decision

    func testGetDecisionToolDefinitionMatchesSchema() throws {
        XCTAssertEqual(D3ToolSchemas.ToolName.getDecision, "leaf_get_decision")

        let schema = D3ToolSchemas.getDecision()
        XCTAssertEqual(schema["type"] as? String, "object")
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)

        let required = schema["required"] as? [String] ?? []
        XCTAssertEqual(required, ["topic"])

        let props = schema["properties"] as? [String: Any] ?? [:]
        XCTAssertEqual((props["topic"] as? [String: Any])?["type"] as? String, "string")

        // Optional `period` follows the same nested shape as queryActivity.
        let period = props["period"] as? [String: Any] ?? [:]
        XCTAssertEqual(period["type"] as? String, "object")
        let periodRequired = period["required"] as? [String] ?? []
        XCTAssertEqual(Set(periodRequired), Set(["start_ms", "end_ms"]))
    }

    // MARK: - leaf_current_work

    func testCurrentWorkToolDefinitionMatchesSchema() throws {
        XCTAssertEqual(D3ToolSchemas.ToolName.currentWork, "leaf_current_work")

        let schema = D3ToolSchemas.currentWork()
        XCTAssertEqual(schema["type"] as? String, "object")
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)

        // No required params — `now_ms` is optional integer override for tests.
        let required = schema["required"] as? [String] ?? []
        XCTAssertTrue(required.isEmpty)

        let props = schema["properties"] as? [String: Any] ?? [:]
        XCTAssertEqual((props["now_ms"] as? [String: Any])?["type"] as? String, "integer")
    }
}
