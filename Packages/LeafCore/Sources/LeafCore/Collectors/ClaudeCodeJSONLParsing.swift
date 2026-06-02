import Foundation

/// Phase 2.3 — protocol for the parser of a single line from a Claude Code session jsonl.
/// The real parser (schema mapping + tool allowlist + ADR-010 filtering of
/// prompt content) lives in `LeafCorePrivate/Prod/Collectors/ClaudeCodeJSONLParser.swift`
/// — that is moat. Public Core ships only the protocol + Stub.
///
/// The context around a line (cwd / git_branch / sessionId / source path) is usually
/// duplicated at the top level of the jsonl-line itself, but is passed explicitly for two
/// reasons: (a) the parser should not be required to look into top-level filesystem context
/// on `.malformed` lines, (b) a source override is useful for tests.
public protocol ClaudeCodeJSONLParsing: Sendable {
    /// Parses ONE line. Returns `[RawEvent]` because a single `assistant`
    /// message may contain several `tool_use` elements in `message.content`.
    /// `source` — abs path to the file for logs; `now` — fallback timestamp if
    /// the line itself has no parseable `timestamp`.
    func parse(line: String, source: String, now: Date) -> ClaudeCodeParseResult
}

/// Result for a single line. `.events` — something useful was parsed (≥0 events;
/// an empty array is also OK — e.g. an `assistant` with a single `text` element and no tool_use).
/// `.irrelevant` — line of a known type that we do not ingest (system / attachment / ...).
/// `.malformed` — JSON parse error or known-schema violation → collector log warning + skip.
public enum ClaudeCodeParseResult: Sendable, Equatable {
    case events([RawEvent])
    case irrelevant
    case malformed(reason: String)
}

/// Public stub — dev/CI builds without moat. Returns `.irrelevant` for everything:
/// an unaligned build does not write AI events (we have no right to guess the schema
/// without moat knowledge). Production uses `ClaudeCodeJSONLParser` from
/// LeafCorePrivate.
public struct StubClaudeCodeJSONLParser: ClaudeCodeJSONLParsing {
    public init() {}

    public func parse(line: String, source: String, now: Date) -> ClaudeCodeParseResult {
        .irrelevant
    }
}
