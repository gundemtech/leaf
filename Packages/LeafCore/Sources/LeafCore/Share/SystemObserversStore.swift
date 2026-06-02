import Foundation
#if canImport(Combine)
import Combine
#endif

/// Phase Track-4 S3 — master toggle for system observers (CGEventTap
/// intensity / clipboard / wifi / vpn / audio_route / mic_in_use / display /
/// screenshot_watcher / downloads_watcher / trash_watcher). UserDefaults-backed,
/// shared suite `tech.gundem.leaf` (the same one as `LocalAppsStore`).
///
/// Default ON for all except `intensity` — it gates the CGEventTap which
/// requires Input Monitoring TCC, so it stays explicit opt-in (see
/// `InputMonitoringPermissionStore` + `PermissionsService`).
public final class SystemObserversStore: ObservableObject, @unchecked Sendable {
    public static let sharedSuiteName = "tech.gundem.leaf"

    /// `nonisolated(unsafe)` — UserDefaults thread-safe per Apple docs;
    /// matches the OAuth-suite global-let pattern from Phase 4.2 + S2 LocalAppsStore.
    public nonisolated(unsafe) static let sharedDefaults: UserDefaults =
        UserDefaults(suiteName: sharedSuiteName) ?? .standard

    /// Observers that are OFF by default. CGEventTap intensity is the only one —
    /// it requires Input Monitoring TCC, so it stays explicit opt-in.
    public static let defaultsOff: Set<String> = ["intensity"]

    /// 10 observers — single source of truth across Agent.main() wiring,
    /// Settings UI (SystemObserversSettingsSection), and tests.
    public static let allObservers: [String] = [
        "intensity",
        "clipboard",
        "wifi",
        "vpn",
        "audio_route",
        "mic_in_use",
        "display",
        "screenshot_watcher",
        "downloads_watcher",
        "trash_watcher"
    ]

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var cache: [String: Bool] = [:]

    public init(defaults: UserDefaults = SystemObserversStore.sharedDefaults) {
        self.defaults = defaults
    }

    public func isEnabled(_ observer: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[observer] { return cached }
        let key = Self.key(observer)
        let value: Bool
        if defaults.object(forKey: key) == nil {
            value = !Self.defaultsOff.contains(observer)
        } else {
            value = defaults.bool(forKey: key)
        }
        cache[observer] = value
        return value
    }

    public func setEnabled(_ observer: String, _ enabled: Bool) {
        lock.lock()
        defaults.set(enabled, forKey: Self.key(observer))
        cache[observer] = enabled
        lock.unlock()
        DispatchQueue.main.async { [self] in
            self.objectWillChange.send()
        }
    }

    public static func key(_ observer: String) -> String {
        "systemObservers.\(observer).enabled"
    }
}
