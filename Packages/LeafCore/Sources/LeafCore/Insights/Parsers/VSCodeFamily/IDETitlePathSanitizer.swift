import Foundation

/// Track-6 P6 — defense-in-depth sanitizer for `ide_window_title_observed`
/// fallback emit. When a user customizes `window.title` and our parsers
/// return nil, we still want to capture the raw title for debugging — but
/// not at the cost of leaking absolute paths from a custom `${activeEditorLong}`
/// substitution. Sanitizer:
///   1. Replaces $HOME prefix with `~/`.
///   2. For any whitespace-token containing `/`, takes the last component
///      (basename). Exception: tokens that start with `~/` after step 1 are
///      kept as-is (informative sanitized path, no leaking of absolute prefix).
///   3. Truncates result to 200 chars (matches planner discipline).
public enum IDETitlePathSanitizer {
    public static let maxLength = 200

    public static func sanitize(_ raw: String) -> String {
        let homePrefix = NSHomeDirectory()
        let tokens = raw.split(separator: " ", omittingEmptySubsequences: false).map { token -> String in
            var s = String(token)
            // Replace $HOME → ~/ prefix.
            if s.hasPrefix(homePrefix) {
                s = "~" + String(s.dropFirst(homePrefix.count))
            }
            // If token now starts with `~/`, keep the sanitized form as-is —
            // it no longer leaks the real home path and is still informative.
            if s.hasPrefix("~/") { return s }
            // If still contains a path-like substring (starts with /),
            // take last component (basename) to drop leading path segments.
            if s.contains("/") {
                let parts = s.split(separator: "/", omittingEmptySubsequences: false)
                if let last = parts.last, !last.isEmpty {
                    s = String(last)
                }
            }
            return s
        }
        var result = tokens.joined(separator: " ")
        if result.count > maxLength {
            result = String(result.prefix(maxLength))
        }
        return result
    }
}
