import Foundation

/// Phase Track-1 D3 — input-schema definitions for the 3 high-level structured
/// MCP tools. Lives in LeafCore (not LeafMCP) so SPM tests can assert the
/// JSON-schema shape without going through xcodebuild — LeafMCP itself has no
/// SPM test target (Xcode-only target, see existing 12 tool shells).
///
/// Schemas are exposed as `static func` (not `static let`) to avoid Swift 6
/// strict-concurrency violations: `[String: Any]` is non-Sendable, so a stored
/// global / type-property would require `@MainActor`. Computed accessors are
/// concurrency-safe and cheap (each call re-builds a tiny dictionary literal).
public enum D3ToolSchemas {

    /// Tool name registry — kept in lock-step with the LeafMCP `tools/list` and
    /// `tools/call` arrays. Renaming requires a coordinated bump (breaking
    /// change for AI-client side, like a `schemaVersion` major).
    public enum ToolName {
        public static let queryActivity = "leaf_query_activity"
        public static let getDecision = "leaf_get_decision"
        public static let currentWork = "leaf_current_work"
    }

    /// `leaf_query_activity` — period required, filter optional FTS string.
    public static func queryActivity() -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "period": [
                    "type": "object",
                    "properties": [
                        "start_ms": ["type": "integer", "description": "Inclusive start (ms epoch)."],
                        "end_ms": ["type": "integer", "description": "Inclusive end (ms epoch)."]
                    ],
                    "required": ["start_ms", "end_ms"],
                    "additionalProperties": false
                ],
                "filter": [
                    "type": "string",
                    "description": "Optional FTS keyword over event bodies (Linear desc/comment, Slack msg, GH PR/issue/review comment, commit msg)."
                ]
            ],
            "required": ["period"],
            "additionalProperties": false
        ]
    }

    /// `leaf_get_decision` — topic required FTS string, period optional `{start_ms, end_ms}`.
    public static func getDecision() -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "topic": [
                    "type": "string",
                    "description": "FTS keyword(s) describing the decision topic (e.g. 'rate limiter algorithm')."
                ],
                "period": [
                    "type": "object",
                    "properties": [
                        "start_ms": ["type": "integer"],
                        "end_ms": ["type": "integer"]
                    ],
                    "required": ["start_ms", "end_ms"],
                    "additionalProperties": false,
                    "description": "Optional ms-epoch range to scope FTS search."
                ]
            ],
            "required": ["topic"],
            "additionalProperties": false
        ]
    }

    /// `leaf_current_work` — no required args; optional `now_ms` for deterministic testing.
    public static func currentWork() -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "now_ms": [
                    "type": "integer",
                    "description": "Optional ms-epoch override for `now` — deterministic testing only."
                ]
            ],
            "additionalProperties": false
        ]
    }
}
