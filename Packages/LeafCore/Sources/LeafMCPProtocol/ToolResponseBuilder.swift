import Foundation

/// Helper for assembling tool-response JSON with a shared `"version"` field.
///
/// All Leaf MCP tools return their payload as a JSON string inside
/// `ToolCallResult.content[0].text`. So that clients (Claude Code and future
/// ones) can distinguish schema versions across Leaf releases, we add a
/// top-level `"version": N` to every payload. Bumping `schemaVersion` is a
/// breaking change for tool consumers.
///
/// This is the **tool-output schema version**, NOT the MCP-protocol version
/// (the MCP protocol version is negotiated in `InitializeHandler`).
public enum ToolResponseBuilder {
    /// Current schema version of tool outputs. Increment only on
    /// breaking changes (renaming a field, changing a type, removing a key).
    /// Adding optional fields is compatible and does not require a bump.
    public static let schemaVersion = 1

    /// Serializes the payload to JSON with `"version": schemaVersion` added
    /// and returns a ready `ToolCallResult`.
    ///
    /// - `payload` must not contain a `"version"` key — it will be overwritten.
    /// - `JSONSerialization` options: `.sortedKeys` for deterministic output.
    public static func versionedJSONResult(_ payload: [String: Any]) throws -> ToolCallResult {
        var p = payload
        p["version"] = schemaVersion
        let data = try JSONSerialization.data(
            withJSONObject: p,
            options: [.sortedKeys]
        )
        let jsonString = String(data: data, encoding: .utf8) ?? "{}"
        return ToolCallResult(
            content: [.text(TextContent(text: jsonString))],
            isError: false
        )
    }
}
