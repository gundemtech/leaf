import Foundation

/// Track 5 / S8 / T1 — per-pref toggle in NotificationsSettingsSection (T9 consumer).
///
/// Maps to the `apns_push` Edge Function `notification_prefs` lookup key (T5 consumer).
/// Display labels bridge raw cases ↔ Track 5 contract §10.2 UI text (cross-spec MIN-1
/// bridge).
///
/// `.handoff` is locked-ON (cannot disable). `.openQuestion` / `.whereStopped` /
/// `.rawActivity` are OFF by default per contract §10.2; the remaining eight cases
/// are ON by default.
public enum NotificationKind: String, CaseIterable, Sendable, Codable, Hashable {
    // Direct messages (3) — sub-group 1
    case handoff
    case task
    case ping
    // Auto-detected (4) — sub-group 2
    case decision
    case blocker
    case openQuestion = "open_question"
    case whereStopped = "where_stopped"
    // Raw activity (1 — collapsed per contract §10.2) — sub-group 3
    case rawActivity = "raw_activity"
    // Behavior (3) — sub-group 4
    case respectFocus = "respect_focus"
    case coalesce
    case sound

    /// Default ON per contract §10.2.
    public var defaultEnabled: Bool {
        switch self {
        case .handoff, .task, .ping, .decision, .blocker, .respectFocus, .coalesce, .sound:
            return true
        case .openQuestion, .whereStopped, .rawActivity:
            return false
        }
    }

    /// Locked-ON per contract §10.2 (cannot disable). Currently only `.handoff`.
    public var locked: Bool {
        self == .handoff
    }

    /// UI display label per contract §10.2.
    public var displayLabel: String {
        switch self {
        case .handoff:       return "Handoff"
        case .task:          return "Task"
        case .ping:          return "Ping"
        case .decision:      return "Decision"
        case .blocker:       return "Blocker"
        case .openQuestion:  return "Open Question"
        case .whereStopped:  return "Where Stopped"
        case .rawActivity:   return "Commit / Linear / Slack mention"
        case .respectFocus:  return "Respect macOS Focus mode"
        case .coalesce:      return "Coalesce 3+/5min into single push"
        case .sound:         return "Sound on direct messages"
        }
    }
}
