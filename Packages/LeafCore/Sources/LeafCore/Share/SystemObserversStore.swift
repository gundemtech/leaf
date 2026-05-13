import Foundation
#if canImport(Combine)
import Combine
#endif

/// Phase Track-4 S3 — master toggle для системных наблюдателей (CGEventTap
/// intensity / clipboard / wifi / vpn / audio_route / mic_in_use / display /
/// screenshot_watcher / downloads_watcher / trash_watcher). UserDefaults-backed,
/// shared suite `tech.gundem.leaf` (та же, что `LocalAppsStore`).
///
/// Default ON для всех, кроме `intensity` — он гейтит CGEventTap который
/// требует Input Monitoring TCC, поэтому остаётся explicit opt-in (см.
/// `InputMonitoringPermissionStore` + `PermissionsService`).
public final class SystemObserversStore: ObservableObject, @unchecked Sendable {
    public static let sharedSuiteName = "tech.gundem.leaf"

    /// `nonisolated(unsafe)` — UserDefaults thread-safe per Apple docs;
    /// matches OAuth-suite global-let pattern из Phase 4.2 + S2 LocalAppsStore.
    public nonisolated(unsafe) static let sharedDefaults: UserDefaults =
        UserDefaults(suiteName: sharedSuiteName) ?? .standard

    /// Observers, которые по умолчанию OFF. CGEventTap intensity единственный —
    /// он требует Input Monitoring TCC, поэтому остаётся explicit opt-in.
    public static let defaultsOff: Set<String> = ["intensity"]

    /// 10 observers — single source of truth между Agent.main() wiring,
    /// Settings UI (SystemObserversSettingsSection) и tests.
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
        if defaults.object(forKey: key) == nil {
            return !Self.defaultsOff.contains(observer)
        }
        return defaults.bool(forKey: key)
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
