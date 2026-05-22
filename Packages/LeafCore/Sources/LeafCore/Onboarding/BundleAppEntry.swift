import Foundation

/// Track-10 T1 — onboarding share-controls preset entry. One row in the
/// preset list shipped by the moat `OnboardingShareTemplateProvider`. The UI
/// renders a flat list of `BundleAppEntry` with per-row toggle + "Accept all"
/// / "Skip" CTAs; "Accept all" writes each entry into `LocalAppsStore`.
///
/// `defaultEnabled` lets the moat preset opt an entry out by default
/// (currently unused — all preset entries ship `true`).
public struct BundleAppEntry: Equatable, Hashable, Sendable {
    public let bundleID: String
    public let displayName: String
    public let defaultEnabled: Bool

    public init(bundleID: String, displayName: String, defaultEnabled: Bool = true) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.defaultEnabled = defaultEnabled
    }
}
