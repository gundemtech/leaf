import Foundation

/// Phase 4.1 — OAuth credentials + workspace identity for third-party providers.
/// One row per provider in the MVP (single-workspace); the multi-workspace move
/// in M005 lifts the PK to a composite (provider, workspace_id).
///
/// Tokens are stored in the same SQLCipher DB as events — symmetric
/// with raw metadata, no new Keychain mechanisms.
public struct IntegrationRecord: Sendable, Hashable {
    public let provider: IntegrationProvider
    public let workspaceID: String
    public let workspaceName: String
    public let accessToken: String
    /// Linear returns a refresh_token even for public PKCE clients (verified
    /// against https://linear.app/developers/oauth-2-0-authentication 2026-04-28).
    /// We store `nil` if the provider never returned one — graceful degrade
    /// in the reconnect-on-expiry flow.
    public let refreshToken: String?
    /// Absolute expiry in epoch-ms. `nil` — long-lived with no expiry (Linear
    /// current: 86399 seconds = 24h, always populated).
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
