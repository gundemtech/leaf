import Foundation

/// Phase Track-1 D3 — body-excerpt cap helper used by `QueryEngine` when
/// projecting `events.payload.body` into `ActivityEvent.bodyExcerpt`.
///
/// The substrate cap (500 chars) is conservative; production callers thread
/// the moat-supplied value (`ProdConfigs.bodyExcerptCap`) through
/// `QueryEngine.bodyExcerptCharCap`. Truncated suffix is a single ellipsis
/// so the resulting string is `charCap + 1` characters in the truncated case.
public enum BodyExcerpt {
    /// Returns `(excerpt, truncated)`. `truncated == true` iff `body.count > charCap`.
    public static func capped(_ body: String, charCap: Int) -> (excerpt: String, truncated: Bool) {
        if body.count <= charCap { return (body, false) }
        let idx = body.index(body.startIndex, offsetBy: charCap)
        return (String(body[..<idx]) + "…", true)
    }
}
