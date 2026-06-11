import Foundation

/// Phase Track-1 D3 — JSON-RPC argument decoders for the 3 high-level structured
/// MCP tools. Lives in LeafCore (not LeafMCP) so SPM tests can exercise the
/// parsing branches without xcodebuild — LeafMCP itself has no SPM test target.
///
/// All decoders are pure / Sendable. They produce either a typed value or a
/// human-readable error message intended to be surfaced as
/// `MCPProtocolError.invalidParams(...)` by the LeafMCP shell.
public enum D3ToolParams {

    /// Result of decoding tool arguments.
    public enum Decoded<T> {
        case ok(T)
        case error(String)
    }

    /// Coerce a JSON-numeric value into Int64. JSON-RPC clients can send
    /// integers as Int (NSNumber) or Int64 — both valid; floating-point or
    /// non-numeric values are rejected.
    public static func int64(_ value: Any?) -> Int64? {
        if let v = value as? Int64 { return v }
        if let v = value as? Int { return Int64(v) }
        if let v = value as? NSNumber {
            // NSNumber wraps Bool too — `Bool` is not a valid numeric here.
            if CFGetTypeID(v) == CFBooleanGetTypeID() { return nil }
            return v.int64Value
        }
        return nil
    }

    /// Decode `{period: {start_ms, end_ms}, filter?: string}` for `leaf_query_activity`.
    public static func decodeQueryActivity(arguments: Any?) -> Decoded<(period: PeriodSpec, filter: String?)> {
        guard let dict = arguments as? [String: Any] else {
            return .error("leaf_query_activity requires {period: {start_ms, end_ms}, filter?: string}")
        }
        guard let periodDict = dict["period"] as? [String: Any] else {
            return .error("missing required 'period' object")
        }
        guard let startMs = int64(periodDict["start_ms"]),
              let endMs = int64(periodDict["end_ms"]) else {
            return .error("period.start_ms and period.end_ms must be integers (ms epoch)")
        }
        let filter = dict["filter"] as? String
        return .ok((PeriodSpec(startMs: startMs, endMs: endMs), filter))
    }

    /// Decode `{topic: string, period?: {start_ms, end_ms}}` for `leaf_get_decision`.
    public static func decodeGetDecision(arguments: Any?) -> Decoded<(topic: String, period: PeriodSpec?, limit: Int)> {
        guard let dict = arguments as? [String: Any] else {
            return .error("leaf_get_decision requires {topic: string, period?: {start_ms, end_ms}}")
        }
        guard let topic = dict["topic"] as? String, !topic.isEmpty else {
            return .error("missing required 'topic' string")
        }
        var period: PeriodSpec? = nil
        if let periodDict = dict["period"] as? [String: Any] {
            guard let startMs = int64(periodDict["start_ms"]),
                  let endMs = int64(periodDict["end_ms"]) else {
                return .error("period.start_ms and period.end_ms must be integers (ms epoch)")
            }
            period = PeriodSpec(startMs: startMs, endMs: endMs)
        }
        let limit = (dict["limit"] as? Int) ?? int64(dict["limit"]).map(Int.init) ?? 1
        return .ok((topic, period, max(1, min(limit, 10))))
    }

    /// Decode `{query: string, period?: {start_ms, end_ms}, limit?: int}` for
    /// `leaf_search` (Track B2).
    public static func decodeSearch(arguments: Any?) -> Decoded<(query: String, period: PeriodSpec?, limit: Int)> {
        guard let dict = arguments as? [String: Any] else {
            return .error("leaf_search requires {query: string, period?: {start_ms, end_ms}, limit?: int}")
        }
        guard let query = dict["query"] as? String,
              !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .error("missing required 'query' string")
        }
        var period: PeriodSpec? = nil
        if let periodDict = dict["period"] as? [String: Any] {
            guard let startMs = int64(periodDict["start_ms"]),
                  let endMs = int64(periodDict["end_ms"]) else {
                return .error("period.start_ms and period.end_ms must be integers (ms epoch)")
            }
            period = PeriodSpec(startMs: startMs, endMs: endMs)
        }
        let limit = (dict["limit"] as? Int) ?? int64(dict["limit"]).map(Int.init) ?? 20
        return .ok((query, period, max(1, min(limit, 50))))
    }

    /// Decode `{now_ms?: integer}` for `leaf_current_work`. No required args —
    /// missing `now_ms` is not an error; caller substitutes wall-clock.
    public static func decodeCurrentWork(arguments: Any?) -> Decoded<Int64?> {
        guard let dict = arguments as? [String: Any] else {
            // Missing arguments object is OK — there are no required params.
            return .ok(nil)
        }
        if dict["now_ms"] == nil {
            return .ok(nil)
        }
        guard let nowMs = int64(dict["now_ms"]) else {
            return .error("now_ms must be an integer (ms epoch) when provided")
        }
        return .ok(nowMs)
    }
}

/// Phase Track-1 D3 — `Codable` → `[String: Any]` bridge for QueryEngine
/// responses. Existing 12 MCP tools return `[String: Any]` directly which
/// flows through `ToolResponseBuilder.versionedJSONResult`. Our 3 D3 tools
/// own typed `Codable` responses (per-response `schemaVersion: "1.0"`); we
/// run them through `JSONEncoder` and back through `JSONSerialization` so
/// they can join the same `versionedJSONResult` path and stamp `version: 1`
/// consistently across all 15 tools.
public enum D3ResponseEncoder {
    public static func toDict<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        let any = try JSONSerialization.jsonObject(with: data, options: [])
        return (any as? [String: Any]) ?? [:]
    }
}
