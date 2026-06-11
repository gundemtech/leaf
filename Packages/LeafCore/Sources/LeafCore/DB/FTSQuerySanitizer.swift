import Foundation

/// Use-case rebuild Track B1 — neutralizes FTS5 query syntax in user text.
///
/// FTS5 MATCH treats bare input as its own query language: hyphens become
/// column filters (`point-fetch` → "no such column: fetch"), unbalanced
/// quotes/parens throw, NOT/OR/AND flip semantics. Search surfaces (in-app
/// Search, `leaf_query_activity` filter, `leaf_get_decision` topic) feed raw
/// user text — every whitespace-separated token is emitted as a quoted string
/// (implicit AND), which both disables operators and keeps hyphenated tokens
/// (GUN-12) whole for the `tokenchars '_-'` tokenizer.
public enum FTSQuerySanitizer {
  public static func sanitize(_ raw: String) -> String {
    raw.split(whereSeparator: \.isWhitespace)
      .map { token in
        "\"" + token.replacingOccurrences(of: "\"", with: "\"\"") + "\""
      }
      .joined(separator: " ")
  }
}
