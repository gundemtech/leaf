import XCTest
@testable import LeafControlMCPProtocol

final class InitializeHandlerTests: XCTestCase {
    func testRespondsWithProtocolVersionAndToolsCapability() async throws {
        let h = InitializeHandler()
        let paramsJSON = #"{"protocolVersion":"2025-11-25","capabilities":{}}"#
        let anyParams = try JSONDecoder().decode(AnyCodable.self, from: Data(paramsJSON.utf8))
        let result = try await h.handle(params: anyParams)
        let data = try JSONEncoder().encode(result)
        let s = String(data: data, encoding: .utf8)!
        XCTAssertTrue(s.contains(#""protocolVersion":"2025-11-25""#), s)
        XCTAssertTrue(s.contains(#""tools""#), s)
        XCTAssertTrue(s.contains(#""name":"leafcontrol""#), s)
    }
}
