import Foundation

/// Phase Track-4 S2 — TCC state for AppleScript per (source binary, target bundle ID).
/// `denied(t)` carries the millisecond timestamp when the deny was recorded so
/// `shouldProbe` can implement the 24h re-probe window without per-tick TCC churn.
public enum AppleScriptPermissionState: Sendable, Equatable {
    case notRequested
    case granted
    case denied(Int64)
    case appNotInstalled
    case unavailable
}

/// Phase Track-4 S2 — UserDefaults-backed per-bundle TCC state cache with 24h
/// denial backoff. Persists across agent restart. `shouldProbe` answers
/// "is it worth invoking NSAppleScript again for this bundle right now?".
@MainActor
public final class AppleScriptPermissionStore {
    private static let denialCacheMs: Int64 = 24 * 3600 * 1000

    private let defaults: UserDefaults

    /// Phase Track-4 S2 — default backing store mirrors `LocalAppsStore`'s
    /// cross-process suite so the Settings UI badge ("Granted" / "Denied" /
    /// "Waiting") and the Agent's collector observe the same TCC state.
    public init(defaults: UserDefaults = LocalAppsStore.sharedDefaults) {
        self.defaults = defaults
    }

    public func cachedState(for bundleID: String) -> AppleScriptPermissionState {
        let stateKey = Self.stateKey(bundleID)
        guard let raw = defaults.string(forKey: stateKey) else { return .notRequested }
        switch raw {
        case "granted":
            return .granted
        case "denied":
            let t = (defaults.object(forKey: Self.deniedAtKey(bundleID)) as? NSNumber)?.int64Value ?? 0
            return .denied(t)
        case "appNotInstalled":
            return .appNotInstalled
        case "unavailable":
            return .unavailable
        default:
            return .notRequested
        }
    }

    public func record(_ state: AppleScriptPermissionState, for bundleID: String, nowMs: Int64) {
        let stateKey = Self.stateKey(bundleID)
        let deniedKey = Self.deniedAtKey(bundleID)
        switch state {
        case .notRequested:
            defaults.removeObject(forKey: stateKey)
            defaults.removeObject(forKey: deniedKey)
        case .granted:
            defaults.set("granted", forKey: stateKey)
            defaults.removeObject(forKey: deniedKey)
        case .denied(let t):
            defaults.set("denied", forKey: stateKey)
            defaults.set(NSNumber(value: t), forKey: deniedKey)
        case .appNotInstalled:
            defaults.set("appNotInstalled", forKey: stateKey)
            defaults.removeObject(forKey: deniedKey)
        case .unavailable:
            defaults.set("unavailable", forKey: stateKey)
            defaults.removeObject(forKey: deniedKey)
        }
    }

    public func shouldProbe(for bundleID: String, nowMs: Int64) -> Bool {
        switch cachedState(for: bundleID) {
        case .notRequested: return true
        case .granted: return true
        case .denied(let t): return (nowMs - t) > Self.denialCacheMs
        case .appNotInstalled: return false
        case .unavailable: return false
        }
    }

    private static func stateKey(_ bundleID: String) -> String {
        "appleScript.permission.state.\(bundleID)"
    }
    private static func deniedAtKey(_ bundleID: String) -> String {
        "appleScript.permission.deniedAtMs.\(bundleID)"
    }
}
