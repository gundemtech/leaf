import Foundation
#if canImport(Combine)
import Combine
#endif

/// Phase Track-4 S2 — user's Settings → Local Apps preferences (per-app enabled
/// flag + per-(app, sub-field) opt-in flag). UserDefaults-backed; mutations
/// trigger `objectWillChange` so the Settings UI re-renders. Independent of
/// the AppleScript permission state cache (which tracks TCC, not user intent).
///
/// Sub-field opt-ins gate the highest-fidelity third-party PII signals:
///  - Mail "mailboxName"        — emits `mail_active_mailbox_changed` if true
///  - Zoom "ownMeetingTopic"    — emits `zoom_meeting_name_observed` if true
///
/// Default is OFF for every (bundleID, field) pair — both at the master toggle
/// and at every sub-field. Opt-in is always explicit.
@MainActor
public final class LocalAppsStore: ObservableObject {
    public private(set) var enabledMap: [String: Bool] = [:]
    public private(set) var subFieldMap: [String: [String: Bool]] = [:]

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func isEnabled(_ bundleID: String) -> Bool {
        if let cached = enabledMap[bundleID] { return cached }
        return defaults.bool(forKey: Self.enabledKey(bundleID))
    }

    public func setEnabled(_ bundleID: String, _ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey(bundleID))
        enabledMap[bundleID] = enabled
        objectWillChange.send()
    }

    public func isSubFieldOptedIn(_ bundleID: String, field: String) -> Bool {
        if let bucket = subFieldMap[bundleID], let cached = bucket[field] { return cached }
        return defaults.bool(forKey: Self.subFieldKey(bundleID, field))
    }

    public func setSubFieldOptedIn(_ bundleID: String, field: String, optedIn: Bool) {
        defaults.set(optedIn, forKey: Self.subFieldKey(bundleID, field))
        var bucket = subFieldMap[bundleID] ?? [:]
        bucket[field] = optedIn
        subFieldMap[bundleID] = bucket
        objectWillChange.send()
    }

    private static func enabledKey(_ bundleID: String) -> String {
        "localApps.enabled.\(bundleID)"
    }
    private static func subFieldKey(_ bundleID: String, _ field: String) -> String {
        "localApps.subField.\(bundleID).\(field)"
    }
}
