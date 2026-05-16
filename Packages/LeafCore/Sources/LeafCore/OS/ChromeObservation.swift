import Foundation

/// Phase Track-4 S2 — Chrome boundary value type. Mirror of `SafariObservation`
/// but kept as a distinct type so per-adapter source-grep tests can assert
/// each adapter's forbidden-field list independently. Incognito tabs are
/// AS-invisible to the script.
///
/// Track-6 P3: `snapshots` carries per-tab descriptors post-granularity
/// filtering. `activeTabKey` mirrors Chrome's stable `tab.id` for the
/// frontmost tab in the active window; empty string when unknown.
public struct ChromeObservation: AdapterObservation, Hashable {
    public let tabs: [BrowserTab]
    public let activeWindowID: String?
    public let snapshots: [TabSnapshot]
    public let activeTabKey: String

    public init(
        tabs: [BrowserTab],
        activeWindowID: String?,
        snapshots: [TabSnapshot] = [],
        activeTabKey: String = ""
    ) {
        self.tabs = tabs
        self.activeWindowID = activeWindowID
        self.snapshots = snapshots
        self.activeTabKey = activeTabKey
    }
}
