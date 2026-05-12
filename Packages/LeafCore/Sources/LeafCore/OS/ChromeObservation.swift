import Foundation

/// Phase Track-4 S2 — Chrome boundary value type. Mirror of `SafariObservation`
/// but kept as a distinct type so per-adapter source-grep tests can assert
/// each adapter's forbidden-field list independently. Incognito tabs are
/// AS-invisible to the script.
public struct ChromeObservation: AdapterObservation, Hashable {
    public let tabs: [BrowserTab]
    public let activeWindowID: String?

    public init(tabs: [BrowserTab], activeWindowID: String?) {
        self.tabs = tabs
        self.activeWindowID = activeWindowID
    }
}
