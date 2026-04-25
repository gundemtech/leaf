import Foundation

/// Phase 2.4 — структура для конфигурации FSEvents ignore-list.
/// Сами patterns — moat (`FSEventsIgnoreRulesProd` в LeafCorePrivate);
/// логика matching универсальна и живёт здесь, чтобы тесты мог дёшево
/// собрать custom rules без moat-зависимости.
public struct FSEventsIgnoreRules: Sendable {
    /// Имена компонентов path'а — если *любой* component совпадает,
    /// path ignored. Пример: `"node_modules"`, `".git"`. Полное-name match,
    /// не glob (точная защита от ложных срабатываний на `node_modules-foo`).
    public let ignoredDirComponents: Set<String>
    /// Расширения файла без точки. Пример: `"swp"`, `"tmp"`.
    public let ignoredExtensions: Set<String>
    /// Полные имена файлов. Пример: `".DS_Store"`.
    public let ignoredFilenames: Set<String>
    /// `LIKE`-glob patterns на filename (`*` matches anything, `?` — single char).
    /// Пример: `"~$*"` (Office lock files), `".~lock.*"` (LibreOffice).
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

    /// True — path должен быть ignored. Order: dir components → filename →
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
    /// Empty rules — `shouldIgnore` always false. Для тестов где нужен router
    /// без ignore-flow.
    public static let empty = FSEventsIgnoreRules()
}
