import XCTest
@testable import LeafMCPProtocol

final class JSONRPCRoundTripTests: XCTestCase {
    func testRequestRoundTripPreservesMethodAndId() throws {
        let json = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#
        let decoded = try JSONDecoder().decode(JSONRPCRequest.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.method, "initialize")
        XCTAssertEqual(decoded.id, .number(1))
        XCTAssertEqual(decoded.jsonrpc, "2.0")
    }

    func testNotificationHasNoIdWhenDecoded() throws {
        let json = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
        let decoded = try JSONDecoder().decode(JSONRPCRequest.self, from: Data(json.utf8))
        XCTAssertNil(decoded.id)
        XCTAssertEqual(decoded.method, "notifications/initialized")
    }

    func testSuccessResponseEncodedMinifiedAndNewlineFree() throws {
        let resp = JSONRPCResponse.success(id: .number(7), result: AnyCodable(["ok": true]))
        let data = try JSONEncoder().encode(resp)
        let s = String(data: data, encoding: .utf8)!
        XCTAssertFalse(s.contains("\n"))
        XCTAssertTrue(s.contains(#""id":7"#), "expected id:7 in \(s)")
        XCTAssertTrue(s.contains(#""jsonrpc":"2.0""#))
    }

    func testErrorResponseCarriesCodeAndMessage() throws {
        let resp = JSONRPCResponse.error(id: .number(3), code: -32601, message: "Method not found")
        let data = try JSONEncoder().encode(resp)
        let s = String(data: data, encoding: .utf8)!
        XCTAssertTrue(s.contains(#""code":-32601"#), s)
        XCTAssertTrue(s.contains(#""message":"Method not found""#), s)
    }
}
