#if os(macOS)
import AppKit
import Foundation

/// Превращает bundle ID (`com.apple.Safari`) в human-readable имя (`Safari`).
/// Три tier'а с fallback'ами:
///
/// 1. `NSRunningApplication` — быстро и актуально для запущенных приложений.
/// 2. `NSWorkspace.urlForApplication(withBundleIdentifier:)` + Info.plist —
///    читает `CFBundleDisplayName` или `CFBundleName` установленного приложения.
/// 3. Bundle ID как есть — последний резерв.
///
/// In-memory LRU-style cache держит resolved names чтобы не пересчитывать
/// на каждом popover refresh'е.
public final class AppNameResolver: @unchecked Sendable {
    public static let shared = AppNameResolver()

    private let queue = DispatchQueue(label: "tech.gundem.leaf.namecache")
    private var cache: [String: String] = [:]

    public init() {}

    public func displayName(for bundleID: String) -> String {
        if let cached = queue.sync(execute: { cache[bundleID] }) {
            return cached
        }
        let resolved = resolveUncached(bundleID: bundleID) ?? bundleID
        queue.sync { cache[bundleID] = resolved }
        return resolved
    }

    /// Сбросить кэш (для тестов, и на случай когда юзер переименовал app).
    public func flushCache() {
        queue.sync { cache.removeAll() }
    }

    private func resolveUncached(bundleID: String) -> String? {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let name = running.localizedName, !name.isEmpty {
            return name
        }

        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let bundle = Bundle(url: url) {
            if let display = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
               !display.isEmpty {
                return display
            }
            if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
               !name.isEmpty {
                return name
            }
        }

        return nil
    }
}
#endif
