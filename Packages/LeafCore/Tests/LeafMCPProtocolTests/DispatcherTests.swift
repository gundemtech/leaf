import XCTest
@testable import LeafMCPProtocol

final class DispatcherTests: XCTestCase {
    func testUnknownMethodReturnsMethodNotFound() async throws {
        let d = Dispatcher(handlers: [:])
        let req = JSONRPCRequest(id: .number(1), method: "no/such/method", params: nil)
        let resp = await d.dispatch(req)
        XCTAssertEqual(resp?.error?.code, JSONRPCErrorCode.methodNotFound)
    }

    func testKnownMethodRoutesToHandler() async throws {
        struct Echo: MethodHandler {
            var method: String { "echo" }
            func handle(params: AnyCodable?) async throws -> AnyCodable {
                AnyCodable(["echoed": true])
            }
        }
        let d = Dispatcher(handlers: ["echo": Echo()])
        let req = JSONRPCRequest(id: .number(2), method: "echo", params: nil)
        let resp = await d.dispatch(req)
        XCTAssertNil(resp?.error)
        XCTAssertNotNil(resp?.result)
    }

    func testNotificationProducesNoResponse() async throws {
        let d = Dispatcher(handlers: [:])
        let req = JSONRPCRequest(id: nil, method: "notifications/initialized", params: nil)
        let resp = await d.dispatch(req)
        XCTAssertNil(resp)
    }

    func testHandlerThrowingMCPProtocolErrorMapsToJSONRPC() async throws {
        struct BadHandler: MethodHandler {
            var method: String { "bad" }
            func handle(params: AnyCodable?) async throws -> AnyCodable {
                throw MCPProtocolError.invalidParams("period must be one of today/yesterday/last_7_days")
            }
        }
        let d = Dispatcher(handlers: ["bad": BadHandler()])
        let req = JSONRPCRequest(id: .number(3), method: "bad", params: nil)
        let resp = await d.dispatch(req)
        XCTAssertEqual(resp?.error?.code, JSONRPCErrorCode.invalidParams)
        XCTAssertTrue(resp?.error?.message.contains("period") ?? false)
    }
}
