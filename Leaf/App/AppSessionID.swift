import Foundation

enum AppSessionID {
    /// Fresh UUID per app launch. Used as the "current session" stamp for
    /// session-dismiss flows (e.g. the GitHub re-auth banner on Home —
    /// dismiss persists in UserDefaults keyed by this id, naturally clearing
    /// on the next launch when a new UUID is minted).
    static let current: String = UUID().uuidString
}
