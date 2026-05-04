import Foundation

/// Phase 4.7.A — cross-provider Linear ID extraction. Pure function, no I/O.
///
/// Extracts Linear-shaped issue IDs (e.g. "LEAF-123", "ENG-9999") из произвольного
/// текста + validates prefix против whitelist (Linear team-keys из integration
/// record / `viewer.teams { key }`). Применяется в hooks: GitHub commit message,
/// GitHub PR title (Phase 4.7.A); Slack message text — отложен в Track B
/// (aggregate semantics conflict; см. plan A-4).
///
/// **ADR-010 invariant:** extractor работает на already-in-memory text; matched
/// ID (substring) копируется в payload, body-text discard'ится в caller'е до
/// payload-finalize step. Никогда не персистит body.
///
/// **Pattern:** `[A-Z][A-Z0-9]{1,4}-\d+` — первая буква обязательно alpha,
/// 1-4 следующих символов могут быть alphanumeric (Linear позволяет team
/// keys типа "LEAF" или "TEAM2"). Word boundary anchored. Case-sensitive
/// (lowercase intentionally rejected — reduces false positives на natural
/// English с suffix чисел).
public enum LinearIDExtractor {

    /// Force-try OK — pattern constant, validated в test suite.
    private static let pattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"\b([A-Z][A-Z0-9]{1,4})-(\d+)\b"#, options: [])
    }()

    /// Extracts first Linear-ID-shaped match с known prefix. Returns full ID
    /// (e.g. "LEAF-456") если matched + prefix в whitelist. `nil` иначе.
    /// Multiple matches → first one wins (most-recent-context heuristic;
    /// commit message subject обычно ставит intent впереди).
    /// Empty `knownPrefixes` → returns nil immediately (graceful no-op
    /// если Linear collector ещё не initialized).
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
}

/// Phase 4.7.A — in-memory TTL cache для Linear team-key prefixes.
/// Backed by a fetcher closure (refreshed на access if cache stale).
/// Single-instance per app process; зависит от Linear collector wiring
/// (Phase 4.7.B / онбординг). До первого refresh'а — empty set, extractor
/// returns nil — graceful no-op.
public actor LinearIDPrefixCache {
    private let fetcher: @Sendable () async -> Set<String>
    private let ttl: TimeInterval
    private var cached: Set<String>
    private var lastRefreshAt: Date?

    /// `fetcher` — closure возвращающая current team-key set (e.g. wrapping
    /// Linear `viewer.teams { key }` query). На любую ошибку fetcher должен
    /// вернуть empty set — cache trust'ает return value.
    /// `ttl` — сколько cache живёт после refresh; default 1 час.
    public init(
        fetcher: @escaping @Sendable () async -> Set<String>,
        ttl: TimeInterval = 3600
    ) {
        self.fetcher = fetcher
        self.ttl = ttl
        self.cached = []
        self.lastRefreshAt = nil
    }

    /// Возвращает текущий prefix set. Если cache stale (> ttl с последнего
    /// refresh) или ещё не initialized — fetches asynchronously, обновляет
    /// cache, возвращает свежий результат.
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

    /// Force-refresh cache (e.g. после Linear reconnect / integration change).
    public func invalidate() {
        lastRefreshAt = nil
    }
}
