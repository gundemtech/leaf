import Foundation

/// Phase Track-4 S2 — Arc boundary value type. Mirror shape to Safari/Chrome
/// observations; Arc's AS dict ships intermittently across versions, so the
/// adapter parser must be defensively tolerant of empty results.
///
/// Track-6 P3: `snapshots` carries per-tab descriptors post-granularity
/// filtering. `activeTabKey` mirrors Arc's stable `tab.id` for the frontmost
/// tab; empty string when unknown or when AS dict returns no result.
public struct ArcObservation: AdapterObservation, Hashable {
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
