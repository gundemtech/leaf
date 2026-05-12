import Foundation

/// Phase Track-4 S2 — narrow tab descriptor shared by Safari / Chrome / Arc
/// observations. Only the user-visible identifiers (title + URL) cross the
/// boundary. `source of`, `text of`, history items, cookies, localStorage —
/// none of these have a property on this value type, and the per-adapter
/// source-grep tests assert they never appear in the AS scripts either.
public struct BrowserTab: Sendable, Hashable, Codable {
    public let title: String
    public let url: String

    public init(title: String, url: String) {
        self.title = title
        self.url = url
    }
}
