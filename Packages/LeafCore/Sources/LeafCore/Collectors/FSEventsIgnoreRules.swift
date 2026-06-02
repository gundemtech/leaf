import Foundation

/// Phase 2.4 — configuration struct for the FSEvents ignore-list.
/// The patterns themselves are moat (`FSEventsIgnoreRulesProd` in LeafCorePrivate);
/// the matching logic is generic and lives here so that tests can cheaply
/// assemble custom rules without a moat dependency.
public struct FSEventsIgnoreRules: Sendable {
    /// Path component names — if *any* component matches, the
    /// path is ignored. Example: `"node_modules"`, `".git"`. Full-name match,
    /// not glob (precise protection against false positives on `node_modules-foo`).
    public let ignoredDirComponents: Set<String>
    /// File extensions without the dot. Example: `"swp"`, `"tmp"`.
    public let ignoredExtensions: Set<String>
    /// Full file names. Example: `".DS_Store"`.
    public let ignoredFilenames: Set<String>
    /// `LIKE`-glob patterns on the filename (`*` matches anything, `?` — single char).
    /// Example: `"~$*"` (Office lock files), `".~lock.*"` (LibreOffice).
    public let ignoredFilenameGlobs: [String]

    public init(
        ignoredDirComponents: Set<String> = [],
        ignoredExtensions: Set<String> = [],
        ignoredFilenames: Set<String> = [],
        ignoredFilenameGlobs: [String] = []
    ) {
        self.ignoredDirComponents = ignoredDirComponents
        self.ignoredExtensions = ignoredExtensions
        self.ignoredFilenames = ignoredFilenames
        self.ignoredFilenameGlobs = ignoredFilenameGlobs
    }

    /// True — the path should be ignored. Order: dir components → filename →
    /// extension → globs (cheapest first).
    public func shouldIgnore(path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        for component in url.pathComponents {
            if ignoredDirComponents.contains(component) { return true }
        }
        let filename = url.lastPathComponent
        if ignoredFilenames.contains(filename) { return true }
        let ext = url.pathExtension
        if !ext.isEmpty && ignoredExtensions.contains(ext) { return true }
        for glob in ignoredFilenameGlobs {
            if NSPredicate(format: "SELF LIKE %@", glob).evaluate(with: filename) {
                return true
            }
        }
        return false
    }
}

extension FSEventsIgnoreRules {
    /// Empty rules — `shouldIgnore` always false. For tests that need a router
    /// without the ignore-flow.
    public static let empty = FSEventsIgnoreRules()
}
