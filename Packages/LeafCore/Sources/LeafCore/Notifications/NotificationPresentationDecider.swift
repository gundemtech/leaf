import Foundation

/// Settings dead-toggle remediation (WS2) — plain result of the foreground
/// notification-presentation decision. The app maps this to
/// `UNNotificationPresentationOptions` (keeps UserNotifications out of LeafCore).
public struct NotificationPresentation: Equatable, Sendable {
    public let banner: Bool
    public let sound: Bool
    public let badge: Bool

    public init(banner: Bool, sound: Bool, badge: Bool) {
        self.banner = banner
        self.sound = sound
        self.badge = badge
    }
}

/// Pure decision for how to present a notification delivered while Leaf is in
/// the foreground (the only moment `willPresent` fires). Background delivery is
/// governed server-side and is out of scope here.
public enum NotificationPresentationDecider {
    /// Coalesce window + threshold — ordinary client constants (not moat).
    static let coalesceWindowMs: Int64 = 5 * 60 * 1000
    static let coalesceThreshold = 3

    /// `recentPresentationsMs` are timestamps of prior foreground presentations.
    /// Badge is always kept (a silent count is never intrusive); banner + sound
    /// are dropped when respecting an active Focus or coalescing a burst.
    public static func decide(
        soundEnabled: Bool,
        respectFocus: Bool,
        inFocus: Bool,
        coalesceEnabled: Bool,
        recentPresentationsMs: [Int64],
        nowMs: Int64
    ) -> NotificationPresentation {
        var banner = true
        var sound = soundEnabled

        if respectFocus && inFocus {
            banner = false
            sound = false
        }
        if coalesceEnabled {
            let inWindow = recentPresentationsMs.filter { nowMs - $0 < coalesceWindowMs }
            if inWindow.count >= coalesceThreshold {
                banner = false
                sound = false
            }
        }
        return NotificationPresentation(banner: banner, sound: sound, badge: true)
    }
}
