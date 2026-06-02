#if os(macOS)
import AppKit
import Foundation

/// Resolves a bundle ID into the application's `NSImage` icon with an in-memory cache.
/// AppKit-specific, so it lives in the Leaf target rather than in LeafCore.
///
/// Used by SessionRow and other views to render the real app icon
/// next to the context label instead of a generic SF symbol.
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
