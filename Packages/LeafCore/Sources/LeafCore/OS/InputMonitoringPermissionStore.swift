import Foundation

/// Phase Track-4 S3 — TCC state для Input Monitoring (CGEventTap requires
/// kIOHIDRequestTypeListenEvent). Mirror `AppleScriptPermissionState` shape
/// (S2 precedent) с 24h denial backoff. Single-row state (не per-bundle),
/// поскольку Input Monitoring — TCC уровня процесса, не пары source/target.
public enum InputMonitoringPermissionState: Equatable, Sendable {
    case notRequested
    case granted
    case denied(Int64)  // ms epoch когда зарегистрировано
    case unavailable
}

/// Phase Track-4 S3 — UserDefaults-backed Input Monitoring TCC state cache.
/// 24h denial backoff чтобы CGEventTapCollector не дёргал TCC API каждые 60с
/// флэш-loop'а на устройстве, где юзер уже отказал. Per-process state — нет
/// `bundleID` параметра, т.к. Input Monitoring TCC scoped не к target app
/// (как AppleScript), а к запрашивающему процессу.
public final class InputMonitoringPermissionStore: @unchecked Sendable {
    public static let denialBackoffMs: Int64 = 24 * 3600 * 1000

    public static let stateKey = "systemObservers.inputMonitoring.state"
    public static let deniedAtMsKey = "systemObservers.inputMonitoring.deniedAtMs"

    private let defaults: UserDefaults

    /// Default backing store — shared suite `tech.gundem.leaf` (та же, что
    /// `LocalAppsStore` / `SystemObserversStore`). Cross-process visibility:
    /// Settings UI читает кэш Agent'а и наоборот.
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
        case .granted: return true  // re-check: юзер мог revoke в System Settings
        case .denied(let t): return (nowMs - t) > Self.denialBackoffMs
        case .unavailable: return false
        }
    }
}
