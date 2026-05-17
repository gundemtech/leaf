import Foundation

/// Per-launch dismiss state UserDefaults keys для GitHub / Slack OAuth scope drift banners.
/// Shared между `HomeView`, `GitHubDetailViewModel`, `SlackDetailViewModel` чтобы один dismiss
/// (в Home или detail) скрывал banner в обоих местах для current session. App restart →
/// новый AppSessionID → banner возвращается если scope still outdated.
enum ReauthBannerKeys {
    static let github = "github.reauth.bannerDismissedSessionID"
    static let slack = "slack.reauth.bannerDismissedSessionID"

    /// Read saved session-ID dismiss state для given provider key.
    /// Returns `true` если user dismissed banner в current launch
    /// (saved == AppSessionID.current).
    static func isDismissed(_ key: String) -> Bool {
        guard let saved = UserDefaults.standard.string(forKey: key) else { return false }
        return saved == AppSessionID.current
    }

    /// Write current session-ID as dismiss marker.
    static func markDismissed(_ key: String) {
        UserDefaults.standard.set(AppSessionID.current, forKey: key)
    }

    /// Clear dismiss state (e.g. когда scope refreshed и banner больше не needed).
    static func clearDismissed(_ key: String) {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
