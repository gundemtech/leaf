import Foundation

/// JSON-RPC id может быть number или string per spec. Null отдельно не моделируем —
/// см. known limitations в plan'е (parse-error response с id:null MVP не поддерживает).
public enum JSONRPCID: Codable, Hashable, Sendable {
    case number(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) {
            self = .number(i)
            return
        }
        if let s = try? c.decode(String.self) {
            self = .string(s)
            return
        }
        throw DecodingError.typeMismatch(
            Self.self,
            .init(codingPath: decoder.codingPath, debugDescription: "id must be number or string")
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let i): try c.encode(i)
        case .string(let s): try c.encode(s)
        }
    }
}

/// Type-erased JSON value для params / result / error.data.
/// `@unchecked Sendable` т.к. `value: Any` фактически всегда immutable JSON primitive
/// (Bool/Int/Double/String/NSNull) или рекурсивная структура того же — см. decode/encode.
public struct AnyCodable: Codable, @unchecked Sendable {
    public let value: Any

    public init(_ value: Any) { self.value = value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self.value = NSNull()
            return
        }
        if let b = try? c.decode(Bool.self) {
            self.value = b
            return
        }
        if let i = try? c.decode(Int.self) {
            self.value = i
            return
        }
        if let d = try? c.decode(Double.self) {
            self.value = d
            return
        }
        if let s = try? c.decode(String.self) {
            self.value = s
            return
        }
        if let a = try? c.decode([Self].self) {
            self.value = a.map(\.value)
            return
        }
        if let o = try? c.decode([String: Self].self) {
            self.value = o.mapValues(\.value)
            return
        }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case is NSNull: try c.encodeNil()
        case let b as Bool: try c.encode(b)
        case let i as Int: try c.encode(i)
        case let d as Double: try c.encode(d)
        case let s as String: try c.encode(s)
        case let a as [Any]: try c.encode(a.map(Self.init))
        case let o as [String: Any]: try c.encode(o.mapValues(Self.init))
        default:
            let ctx = EncodingError.Context(
                codingPath: encoder.codingPath,
                debugDescription: "Unsupported JSON value: \(type(of: value))"
            )
            throw EncodingError.invalidValue(value, ctx)
        }
    }
}

public struct JSONRPCRequest: Codable, Sendable {
    public let jsonrpc: String
    public let id: JSONRPCID?  // nil = notification per JSON-RPC 2.0
    public let method: String
    public let params: AnyCodable?

    public init(id: JSONRPCID?, method: String, params: AnyCodable?) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct JSONRPCErrorObject: Codable, Sendable {
    public let code: Int
    public let message: String
    public let data: AnyCodable?

    public init(code: Int, message: String, data: AnyCodable? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

public struct JSONRPCResponse: Codable, Sendable {
    public let jsonrpc: String
    public let id: JSONRPCID
    public let result: AnyCodable?
    public let error: JSONRPCErrorObject?

    public static func success(id: JSONRPCID, result: AnyCodable) -> Self {
        Self(jsonrpc: "2.0", id: id, result: result, error: nil)
    }

    public static func error(id: JSONRPCID, code: Int, message: String, data: AnyCodable? = nil) -> Self {
        Self(
            jsonrpc: "2.0", id: id, result: nil,
            error: JSONRPCErrorObject(code: code, message: message, data: data)
        )
    }
}

/// Standard JSON-RPC 2.0 error codes. MCP spec использует стандартные —
/// tool-level errors идут в result.isError, не в error.code.
public enum JSONRPCErrorCode {
    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603
}
