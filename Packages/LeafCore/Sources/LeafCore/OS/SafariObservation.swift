import Foundation

/// Phase Track-4 S2 — Safari boundary value type. Tabs list + active window
/// ID cross; never source of tab, text of tab, history, cookies, localStorage.
/// Private windows excluded by Safari's AS dictionary itself (we rely on
/// the OS behavior — no explicit filter in the adapter).
public struct SafariObservation: AdapterObservation, Hashable {
    public let tabs: [BrowserTab]
    public let activeWindowID: String?

    public init(tabs: [BrowserTab], activeWindowID: String?) {
        self.tabs = tabs
        self.activeWindowID = activeWindowID
    }
}
