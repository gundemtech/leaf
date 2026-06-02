#if os(macOS)
import AppKit
import Foundation

/// Turns a bundle ID (`com.apple.Safari`) into a human-readable name (`Safari`).
/// Three tiers with fallbacks:
///
/// 1. `NSRunningApplication` — fast and up to date for running applications.
/// 2. `NSWorkspace.urlForApplication(withBundleIdentifier:)` + Info.plist —
///    reads `CFBundleDisplayName` or `CFBundleName` of the installed application.
/// 3. The bundle ID as-is — last resort.
///
/// An in-memory LRU-style cache holds resolved names so we don't recompute
/// on every popover refresh.
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

    /// Flush the cache (for tests, and in case the user renamed an app).
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
