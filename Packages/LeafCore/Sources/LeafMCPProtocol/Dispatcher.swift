import Foundation

public enum MCPProtocolError: Error {
    case invalidParams(String)
    case internalError(String)

    var code: Int {
        switch self {
        case .invalidParams: return JSONRPCErrorCode.invalidParams
        case .internalError: return JSONRPCErrorCode.internalError
        }
    }

    var message: String {
        switch self {
        case .invalidParams(let s): return s
        case .internalError(let s): return s
        }
    }
}

public protocol MethodHandler: Sendable {
    var method: String { get }
    func handle(params: AnyCodable?) async throws -> AnyCodable
}

public struct Dispatcher: Sendable {
    public let handlers: [String: any MethodHandler]

    public init(handlers: [String: any MethodHandler]) {
        self.handlers = handlers
    }

    /// Returns nil for notifications (no `id`) — caller MUST NOT write a response.
    public func dispatch(_ request: JSONRPCRequest) async -> JSONRPCResponse? {
        // JSON-RPC 2.0: a notification = a request without an id. We short-circuit
        // before actually dispatching to a handler — no dedicated handler for
        // notifications needs to be registered.
        guard let id = request.id else { return nil }

        guard let handler = handlers[request.method] else {
            return .error(
                id: id,
                code: JSONRPCErrorCode.methodNotFound,
                message: "Method not found: \(request.method)"
            )
        }

        do {
            let result = try await handler.handle(params: request.params)
            return .success(id: id, result: result)
        } catch let e as MCPProtocolError {
            return .error(id: id, code: e.code, message: e.message)
        } catch {
            return .error(
                id: id,
                code: JSONRPCErrorCode.internalError,
                message: "\(error)"
            )
        }
    }
}
