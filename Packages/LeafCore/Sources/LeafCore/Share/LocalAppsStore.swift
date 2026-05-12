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
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var enabledCache: [String: Bool] = [:]
    private var subFieldCache: [String: [String: Bool]] = [:]

    public init(defaults: UserDefaults = .standard) {
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
        objectWillChange.send()
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
        objectWillChange.send()
    }

    private static func enabledKey(_ bundleID: String) -> String {
        "localApps.enabled.\(bundleID)"
    }
    private static func subFieldKey(_ bundleID: String, _ field: String) -> String {
        "localApps.subField.\(bundleID).\(field)"
    }
}
