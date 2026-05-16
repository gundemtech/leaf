import Foundation
#if canImport(Combine)
import Combine
#endif

/// Phase Track-4 S2 — user's Settings → Local Apps preferences (per-app enabled
/// flag + per-(app, sub-field) opt-in flag). UserDefaults-backed.
///
/// Both the Agent's AppleScriptCollector (poll-tick dispatch) and the main
/// app's `LocalAppsSettingsSection` SwiftUI surface read/write the same
/// suite, so this type is plain `Sendable` (not `@MainActor`) — UserDefaults
/// reads/writes are thread-safe and the internal in-memory cache is guarded
/// by an NSLock. SwiftUI consumers observe via `ObservableObject`; the
/// `objectWillChange` publisher fires whenever a setter runs (downstream
/// dispatching to main is handled by Combine).
///
/// Sub-field opt-ins gate the highest-fidelity third-party PII signals:
///  - Mail "mailboxName"        — emits `mail_active_mailbox_changed` if true
///  - Zoom "ownMeetingTopic"    — emits `zoom_meeting_name_observed` if true
///
/// Default is OFF for every (bundleID, field) pair — opt-in is always explicit.
public final class LocalAppsStore: ObservableObject, @unchecked Sendable {
    /// Phase Track-4 S2 — shared UserDefaults suite between LeafAgent
    /// (`tech.gundem.leaf.agent`) and the main app (`tech.gundem.leaf`).
    /// Mirrors the OAuth pattern (`LinearOAuthEndpoints.userDefaultsSuite`
    /// etc): both processes read/write the same plist so the Settings UI
    /// can talk to the Agent's collector without an IPC channel.
    public static let sharedSuiteName = "tech.gundem.leaf"

    /// Default backing store: the shared suite, falling back to `.standard`
    /// if suite creation fails (matches OAuth defensive pattern).
    /// `nonisolated(unsafe)` — UserDefaults is Apple-NSObject (not Sendable
    /// per its declaration) but is documented as thread-safe by Apple, and
    /// matches the OAuth-suite global-let pattern shipped since Phase 4.2.
    public nonisolated(unsafe) static let sharedDefaults: UserDefaults =
        UserDefaults(suiteName: sharedSuiteName) ?? .standard

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var enabledCache: [String: Bool] = [:]
    private var subFieldCache: [String: [String: Bool]] = [:]

    public init(defaults: UserDefaults = LocalAppsStore.sharedDefaults) {
        self.defaults = defaults
    }

    public func isEnabled(_ bundleID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let cached = enabledCache[bundleID] { return cached }
        return defaults.bool(forKey: Self.enabledKey(bundleID))
    }

    public func setEnabled(_ bundleID: String, _ enabled: Bool) {
        lock.lock()
        defaults.set(enabled, forKey: Self.enabledKey(bundleID))
        enabledCache[bundleID] = enabled
        lock.unlock()
        // SwiftUI requires objectWillChange on main. We hop async so the
        // Agent's @MainActor collector + the main app's SwiftUI Settings
        // surface both observe predictably regardless of caller actor.
        DispatchQueue.main.async { [self] in
            self.objectWillChange.send()
        }
    }

    public func isSubFieldOptedIn(_ bundleID: String, field: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let bucket = subFieldCache[bundleID], let cached = bucket[field] { return cached }
        return defaults.bool(forKey: Self.subFieldKey(bundleID, field))
    }

    public func setSubFieldOptedIn(_ bundleID: String, field: String, optedIn: Bool) {
        lock.lock()
        defaults.set(optedIn, forKey: Self.subFieldKey(bundleID, field))
        var bucket = subFieldCache[bundleID] ?? [:]
        bucket[field] = optedIn
        subFieldCache[bundleID] = bucket
        lock.unlock()
        DispatchQueue.main.async { [self] in
            self.objectWillChange.send()
        }
    }

    private static func enabledKey(_ bundleID: String) -> String {
        "localApps.enabled.\(bundleID)"
    }
    private static func subFieldKey(_ bundleID: String, _ field: String) -> String {
        "localApps.subField.\(bundleID).\(field)"
    }

    // MARK: - Phase Track-6 P2 — System Observers
    //
    // The DerivedData watcher is a separate user-visible toggle from the
    // per-app Xcode master gate. Both must be ON for the watcher to start;
    // either being OFF makes the watcher a no-op (mirror Track-4 S3 pattern
    // for IntensityCollector / FSEvents routers).

    public static let kDerivedDataWatcherEnabled =
        "localApps.systemObservers.derivedDataWatcherEnabled"

    public func derivedDataWatcherEnabled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return defaults.bool(forKey: Self.kDerivedDataWatcherEnabled)
    }

    public func setDerivedDataWatcherEnabled(_ on: Bool) {
        lock.lock()
        defaults.set(on, forKey: Self.kDerivedDataWatcherEnabled)
        lock.unlock()
        DispatchQueue.main.async { [self] in
            self.objectWillChange.send()
        }
    }
}
