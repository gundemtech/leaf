import Foundation

/// Phase 4.7.A — cross-provider Linear ID extraction. Pure function, no I/O.
///
/// Extracts Linear-shaped issue IDs (e.g. "LEAF-123", "ENG-9999") from arbitrary
/// text + validates the prefix against a whitelist (Linear team-keys from the integration
/// record / `viewer.teams { key }`). Used in hooks: GitHub commit message,
/// GitHub PR title (Phase 4.7.A); Slack message text — deferred to Track B
/// (aggregate semantics conflict; see plan A-4).
///
/// **ADR-010 invariant:** the extractor works on already-in-memory text; the matched
/// ID (substring) is copied into the payload, and the body-text is discarded in the caller before
/// the payload-finalize step. Never persists the body.
///
/// **Pattern:** `[A-Z][A-Z0-9]{1,4}-\d+` — the first letter must be alpha,
/// the next 1-4 characters may be alphanumeric (Linear allows team
/// keys like "LEAF" or "TEAM2"). Word boundary anchored. Case-sensitive
/// (lowercase intentionally rejected — reduces false positives on natural
/// English with number suffixes).
public enum LinearIDExtractor {

    /// Force-try OK — pattern constant, validated in the test suite.
    private static let pattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"\b([A-Z][A-Z0-9]{1,4})-(\d+)\b"#, options: [])
    }()

    /// Extracts the first Linear-ID-shaped match with a known prefix. Returns the full ID
    /// (e.g. "LEAF-456") if matched + prefix in the whitelist. `nil` otherwise.
    /// Multiple matches → first one wins (most-recent-context heuristic;
    /// a commit message subject usually puts the intent up front).
    /// Empty `knownPrefixes` → returns nil immediately (graceful no-op
    /// if the Linear collector is not initialized yet).
    public static func extract(text: String, knownPrefixes: Set<String>) -> String? {
        guard !text.isEmpty, !knownPrefixes.isEmpty else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        let matches = pattern.matches(in: text, options: [], range: range)
        for match in matches {
            guard
                let prefixRange = Range(match.range(at: 1), in: text),
                let fullRange = Range(match.range, in: text)
            else { continue }
            let prefix = String(text[prefixRange])
            if knownPrefixes.contains(prefix) {
                return String(text[fullRange])
            }
        }
        return nil
    }

    /// Phase Track-1 D2 — returns ALL Linear-ID matches from `text`, ordered by
    /// appearance, deduped (preserving first-seen order). Empty `knownPrefixes`
    /// → []. No matches → []. Sibling to `extract(text:knownPrefixes:)` (which
    /// returns first match only); `extract` semantics untouched.
    public static func extractAll(text: String, knownPrefixes: Set<String>) -> [String] {
        guard !text.isEmpty, !knownPrefixes.isEmpty else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        let matches = pattern.matches(in: text, options: [], range: range)
        var seen = Set<String>()
        var out: [String] = []
        for match in matches {
            guard
                let prefixRange = Range(match.range(at: 1), in: text),
                let fullRange = Range(match.range, in: text)
            else { continue }
            let prefix = String(text[prefixRange])
            guard knownPrefixes.contains(prefix) else { continue }
            let id = String(text[fullRange])
            if seen.insert(id).inserted {
                out.append(id)
            }
        }
        return out
    }
}

/// Phase 4.7.A — in-memory TTL cache for Linear team-key prefixes.
/// Backed by a fetcher closure (refreshed on access if cache stale).
/// Single-instance per app process; depends on Linear collector wiring
/// (Phase 4.7.B / onboarding). Before the first refresh — empty set, extractor
/// returns nil — graceful no-op.
public actor LinearIDPrefixCache {
    private let fetcher: @Sendable () async -> Set<String>
    private let ttl: TimeInterval
    private var cached: Set<String>
    private var lastRefreshAt: Date?

    /// `fetcher` — closure returning the current team-key set (e.g. wrapping the
    /// Linear `viewer.teams { key }` query). On any error the fetcher should
    /// return an empty set — the cache trusts the return value.
    /// `ttl` — how long the cache lives after a refresh; default 1 hour.
    public init(
        fetcher: @escaping @Sendable () async -> Set<String>,
        ttl: TimeInterval = 3600
    ) {
        self.fetcher = fetcher
        self.ttl = ttl
        self.cached = []
        self.lastRefreshAt = nil
    }

    /// Returns the current prefix set. If the cache is stale (> ttl since the last
    /// refresh) or not initialized yet — fetches asynchronously, updates the
    /// cache, returns the fresh result.
    public func currentPrefixes() async -> Set<String> {
        let now = Date()
        if let last = lastRefreshAt, now.timeIntervalSince(last) < ttl {
            return cached
        }
        let fresh = await fetcher()
        cached = fresh
        lastRefreshAt = now
        return fresh
    }

    /// Force-refresh cache (e.g. after a Linear reconnect / integration change).
    public func invalidate() {
        lastRefreshAt = nil
    }
}
