import Foundation

/// Phase 4.1 — OAuth credentials + workspace identity для third-party providers.
/// Один row per provider в MVP (single-workspace); multi-workspace переезд
/// в M005 lift'ит PK на composite (provider, workspace_id).
///
/// Tokens хранятся в той же SQLCipher-DB что и events — симметрично
/// с raw metadata, никаких новых Keychain механизмов.
public struct IntegrationRecord: Sendable, Hashable {
    public let provider: IntegrationProvider
    public let workspaceID: String
    public let workspaceName: String
    public let accessToken: String
    /// Linear возвращает refresh_token и для public PKCE clients (verified
    /// против https://linear.app/developers/oauth-2-0-authentication 2026-04-28).
    /// Сохраняем `nil` если provider никогда не вернул — graceful degrade
    /// в reconnect-on-expiry flow.
    public let refreshToken: String?
    /// Absolute expiry в epoch-ms. `nil` — long-lived без срока (Linear
    /// текущий: 86399 секунд = 24h, всегда заполнено).
    public let expiresAt: Date?
    public let scope: String
    public let connectedAt: Date
    public let updatedAt: Date

    public init(
        provider: IntegrationProvider,
        workspaceID: String,
        workspaceName: String,
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date?,
        scope: String,
        connectedAt: Date,
        updatedAt: Date
    ) {
        self.provider = provider
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
        self.connectedAt = connectedAt
        self.updatedAt = updatedAt
    }
}
