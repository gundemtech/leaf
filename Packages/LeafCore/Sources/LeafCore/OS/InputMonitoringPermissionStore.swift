import Foundation

/// Phase Track-4 S3 — TCC state for Input Monitoring (CGEventTap requires
/// kIOHIDRequestTypeListenEvent). Mirrors the `AppleScriptPermissionState` shape
/// (S2 precedent) with a 24h denial backoff. Single-row state (not per-bundle),
/// because Input Monitoring TCC is process-level, not per source/target pair.
public enum InputMonitoringPermissionState: Equatable, Sendable {
    case notRequested
    case granted
    case denied(Int64)   // ms epoch when recorded
    case unavailable
}

/// Phase Track-4 S3 — UserDefaults-backed Input Monitoring TCC state cache.
/// 24h denial backoff so CGEventTapCollector doesn't hit the TCC API every 60s
/// in a flash-loop on a device where the user already denied. Per-process state — no
/// `bundleID` parameter, since Input Monitoring TCC is scoped not to a target app
/// (like AppleScript) but to the requesting process.
public final class InputMonitoringPermissionStore: @unchecked Sendable {
    public static let denialBackoffMs: Int64 = 24 * 3600 * 1000

    public static let stateKey = "systemObservers.inputMonitoring.state"
    public static let deniedAtMsKey = "systemObservers.inputMonitoring.deniedAtMs"

    private let defaults: UserDefaults

    /// Default backing store — shared suite `tech.gundem.leaf` (the same one as
    /// `LocalAppsStore` / `SystemObserversStore`). Cross-process visibility:
    /// the Settings UI reads the Agent's cache and vice versa.
    public init(defaults: UserDefaults = SystemObserversStore.sharedDefaults) {
        self.defaults = defaults
    }

    public func cachedState() -> InputMonitoringPermissionState {
        guard let raw = defaults.string(forKey: Self.stateKey) else { return .notRequested }
        switch raw {
        case "granted":
            return .granted
        case "denied":
            let t = (defaults.object(forKey: Self.deniedAtMsKey) as? NSNumber)?.int64Value ?? 0
            return .denied(t)
        case "unavailable":
            return .unavailable
        default:
            return .notRequested
        }
    }

    public func record(_ state: InputMonitoringPermissionState, nowMs: Int64) {
        switch state {
        case .notRequested:
            defaults.removeObject(forKey: Self.stateKey)
            defaults.removeObject(forKey: Self.deniedAtMsKey)
        case .granted:
            defaults.set("granted", forKey: Self.stateKey)
            defaults.removeObject(forKey: Self.deniedAtMsKey)
        case .denied(let t):
            defaults.set("denied", forKey: Self.stateKey)
            let stamp = t == 0 ? nowMs : t
            defaults.set(NSNumber(value: stamp), forKey: Self.deniedAtMsKey)
        case .unavailable:
            defaults.set("unavailable", forKey: Self.stateKey)
            defaults.removeObject(forKey: Self.deniedAtMsKey)
        }
    }

    public func shouldProbe(nowMs: Int64) -> Bool {
        switch cachedState() {
        case .notRequested: return true
        case .granted: return true   // re-check: user may have revoked in System Settings
        case .denied(let t): return (nowMs - t) > Self.denialBackoffMs
        case .unavailable: return false
        }
    }
}
