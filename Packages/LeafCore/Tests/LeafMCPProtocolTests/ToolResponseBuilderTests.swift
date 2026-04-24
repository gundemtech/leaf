import XCTest
@testable import LeafMCPProtocol

final class ToolResponseBuilderTests: XCTestCase {
    func testVersionedJSONResultAddsVersionOne() throws {
        let result = try ToolResponseBuilder.versionedJSONResult(["entries": []])
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.content.count, 1)

        guard case .text(let tc) = result.content[0] else {
            return XCTFail("Expected .text content")
        }
        // sortedKeys → "entries" до "version"; substring check устойчив к пробелам.
        XCTAssertTrue(tc.text.contains("\"version\":1"),
                      "Output should contain version:1, got: \(tc.text)")

        // Parse back and assert top-level version == 1.
        let data = Data(tc.text.utf8)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(parsed?["version"] as? Int, 1)
    }

    func testVersionedJSONResultPreservesExistingKeys() throws {
        let payload: [String: Any] = [
            "period": "today",
            "from": "2026-04-24T00:00:00Z",
            "to": "2026-04-25T00:00:00Z",
            "entries": [["bundleID": "com.apple.Xcode", "durationSec": 1800]]
        ]
        let result = try ToolResponseBuilder.versionedJSONResult(payload)

        guard case .text(let tc) = result.content[0] else {
            return XCTFail("Expected .text content")
        }
        let data = Data(tc.text.utf8)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(parsed?["period"] as? String, "today")
        XCTAssertEqual(parsed?["from"] as? String, "2026-04-24T00:00:00Z")
        XCTAssertEqual(parsed?["to"] as? String, "2026-04-25T00:00:00Z")
        XCTAssertEqual(parsed?["version"] as? Int, 1)

        let entries = parsed?["entries"] as? [[String: Any]]
        XCTAssertEqual(entries?.count, 1)
        XCTAssertEqual(entries?[0]["bundleID"] as? String, "com.apple.Xcode")
    }
}
