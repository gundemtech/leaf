import Foundation

/// Phase Track-4 S2 — Arc boundary value type. Mirror shape to Safari/Chrome
/// observations; Arc's AS dict ships intermittently across versions, so the
/// adapter parser must be defensively tolerant of empty results.
public struct ArcObservation: AdapterObservation, Hashable {
    public let tabs: [BrowserTab]
    public let activeWindowID: String?

    public init(tabs: [BrowserTab], activeWindowID: String?) {
        self.tabs = tabs
        self.activeWindowID = activeWindowID
    }
}
