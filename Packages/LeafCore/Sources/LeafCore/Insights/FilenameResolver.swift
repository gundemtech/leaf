import Foundation

/// Phase 2.4 — turns an absolute path into a `displayName` for UI:
/// basename + cache a tooltip of the full path. Pattern is identical to `AppNameResolver`.
///
/// - L4 events store the parent dir as `path` → displayName = "Project/" (basename
///   of the last component + trailing slash for distinction).
/// - L5 events store the full file path → displayName = "main.swift".
public final class FilenameResolver: @unchecked Sendable {
    public static let shared = FilenameResolver()

    private let queue = DispatchQueue(label: "tech.gundem.leaf.filenamecache")
    private var cache: [String: String] = [:]

    public init() {}

    /// Returns the basename (last path component) with a trailing `/` if the path
    /// is a directory. Cache is purely string-based (we don't stat the filesystem).
    public func displayName(for path: String) -> String {
        if let cached = queue.sync(execute: { cache[path] }) {
            return cached
        }
        let resolved = computeDisplayName(for: path)
        queue.sync { cache[path] = resolved }
        return resolved
    }

    /// Reset the cache (for tests).
    public func flushCache() {
        queue.sync { cache.removeAll() }
    }

    private func computeDisplayName(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        guard !name.isEmpty else { return path }
        // Heuristic to distinguish folder vs file: path has no extension — likely a folder (L4).
        // We don't stat the actual filesystem — the path may no longer exist (removed event).
        if url.pathExtension.isEmpty {
            return "\(name)/"
        }
        return name
    }
}
