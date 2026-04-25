import Foundation

/// Phase 2.4 — превращает absolute path в `displayName` для UI:
/// basename + cache tooltip полного path. Pattern идентичен `AppNameResolver`.
///
/// - L4 events хранят parent dir как `path` → displayName = "Project/" (базовое
///   имя последнего компонента + trailing slash для distinction).
/// - L5 events хранят full file path → displayName = "main.swift".
public final class FilenameResolver: @unchecked Sendable {
    public static let shared = FilenameResolver()

    private let queue = DispatchQueue(label: "tech.gundem.leaf.filenamecache")
    private var cache: [String: String] = [:]

    public init() {}

    /// Возвращает basename (последний path component) с trailing `/` если path
    /// — directory. Cache — purely string-based (не stat'аем filesystem).
    public func displayName(for path: String) -> String {
        if let cached = queue.sync(execute: { cache[path] }) {
            return cached
        }
        let resolved = computeDisplayName(for: path)
        queue.sync { cache[path] = resolved }
        return resolved
    }

    /// Сбросить кэш (для тестов).
    public func flushCache() {
        queue.sync { cache.removeAll() }
    }

    private func computeDisplayName(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        guard !name.isEmpty else { return path }
        // Heuristic для distinct'а folder vs file: path не имеет extension — likely folder (L4).
        // Не stat'аем actual filesystem — path может уже не существовать (removed event).
        if url.pathExtension.isEmpty {
            return "\(name)/"
        }
        return name
    }
}
