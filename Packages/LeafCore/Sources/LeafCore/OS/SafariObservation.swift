import Foundation

/// Phase Track-4 S2 — Safari boundary value type. Tabs list + active window
/// ID cross; never source of tab, text of tab, history, cookies, localStorage.
/// Private windows excluded by Safari's AS dictionary itself (we rely on
/// the OS behavior — no explicit filter in the adapter).
///
/// Track-6 P3: `snapshots` carries per-tab descriptors post-granularity
/// filtering (see `applyGranularity`). `currentTabIndex` is the positional
/// index of the frontmost tab in the active window (0-based); -1 when unknown.
public struct SafariObservation: AdapterObservation, Hashable {
    public let tabs: [BrowserTab]
    public let activeWindowID: String?
    public let snapshots: [TabSnapshot]
    public let currentTabIndex: Int

    public init(
        tabs: [BrowserTab],
        activeWindowID: String?,
        snapshots: [TabSnapshot] = [],
        currentTabIndex: Int = 0
    ) {
        self.tabs = tabs
        self.activeWindowID = activeWindowID
        self.snapshots = snapshots
        self.currentTabIndex = currentTabIndex
    }
}
