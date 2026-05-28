import Foundation

extension URLSession {
    /// Phase 5 defence-in-depth — a non-caching session for OAuth token
    /// exchange / refresh and relay traffic. `.ephemeral` keeps nothing on disk;
    /// we additionally null the URL cache, cookie storage, and credential storage
    /// and force cache-bypassing loads so bearer tokens and auth responses are
    /// never persisted. `nonisolated` so it can be used as a default argument in
    /// `@MainActor` initializers.
    public nonisolated static func leafEphemeral() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }
}
