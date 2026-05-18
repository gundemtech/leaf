#if os(macOS)
import AppKit
import Foundation

/// Превращает bundle ID в `NSImage` иконку приложения с in-memory кэшем.
/// AppKit-специфично, поэтому живёт в Leaf target, не в LeafCore.
///
/// Используется view'хами для рендеринга real app icon рядом с context
/// label вместо generic SF symbol.
@MainActor
final class AppIconResolver {
    static let shared = AppIconResolver()

    private var cache: [String: NSImage] = [:]

    private init() {}

    func icon(for bundleID: String, size: CGFloat = 32) -> NSImage? {
        let key = "\(bundleID)@\(Int(size))"
        if let cached = cache[key] { return cached }

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: size, height: size)
        cache[key] = icon
        return icon
    }

    func flushCache() {
        cache.removeAll()
    }
}
#endif
