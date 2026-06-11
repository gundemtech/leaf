import Foundation

/// Decides when to auto-present the in-app "What's New" sheet, by remembering the
/// last release version the user has seen (UserDefaults-backed, mirroring the
/// `LastSeenCursor` pattern). Injectable `defaults` for a UUID-suite test seam.
///
/// Present rules:
/// - Onboarding must be complete (the first-run flow owns the screen; What's New
///   never fights it).
/// - A clean install (no last-seen version) is seeded SILENTLY and never presents —
///   a brand-new user has no "what changed" to catch up on.
/// - Otherwise present iff the running build is strictly newer than last-seen
///   (numeric prerelease ordering via `SemverPrerelease`).
///
/// `shouldPresent` does NOT advance the cursor on the upgrade path — the caller
/// `markSeen`s only after the sheet is actually shown, so a closed/back-grounded
/// window (e.g. right after a Sparkle relaunch) doesn't silently lose the present.
@Observable
@MainActor
public final class WhatsNewTracker {
    public static let userDefaultsKey = "leaf.ui.lastSeenVersion"

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var lastSeenVersion: String? {
        defaults.string(forKey: Self.userDefaultsKey)
    }

    public func markSeen(_ version: String) {
        defaults.set(version, forKey: Self.userDefaultsKey)
    }

    /// Whether to auto-present What's New for `current` (the running build's
    /// `CFBundleShortVersionString`). Seeds silently on a clean install.
    public func shouldPresent(current: String, hasCompletedOnboarding: Bool) -> Bool {
        guard hasCompletedOnboarding else { return false }
        guard let last = lastSeenVersion else {
            markSeen(current)        // clean install → seed, never present
            return false
        }
        guard let currentSemver = SemverPrerelease(current),
              let lastSemver = SemverPrerelease(last)
        else { return false }        // unparseable → don't present
        return currentSemver > lastSemver
    }
}
