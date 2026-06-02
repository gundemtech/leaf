//
//  LinearOAuthEndpoints.swift
//  LeafCore
//
//  Phase 4.1 — endpoint URLs + GraphQL viewer query.
//  Phase 4.2 — moved from Leaf/ to LeafCore for cross-binary access (Agent + main app).
//  Verified against https://linear.app/developers/oauth-2-0-authentication 2026-04-28.
//

import Foundation

public enum LinearOAuthEndpoints {
    /// Authorize URL — the browser flow starts here.
    public static let authorize = URL(string: "https://linear.app/oauth/authorize")!
    /// Token endpoint — POST for grant_type=authorization_code and refresh_token.
    public static let token = URL(string: "https://api.linear.app/oauth/token")!
    /// GraphQL endpoint — single viewer query during the fetchingWorkspace stage,
    /// and (Phase 4.2) issues polling in LinearCollector.
    public static let graphql = URL(string: "https://api.linear.app/graphql")!

    /// Loopback redirect URI. Linear requires an exact-match (port is mandatory,
    /// not variable per RFC 8252 — the Linear docs explicitly show the port in the example).
    /// When changing the port, update the redirect URI in the Linear OAuth app config.
    public static let redirectHost = "127.0.0.1"
    public static let redirectPort: UInt16 = 47823
    public static let redirectPath = "/callback"
    public static var redirectURI: String { "http://\(redirectHost):\(redirectPort)\(redirectPath)" }

    /// Track 5 / S6 T6 — scope bump per A3 brainstorm.
    /// `read` baseline + `issues:create` for cross-post (narrower than full `write`).
    /// Existing connected users on `read` only must re-authorize via Connections
    /// settings; UI banner surfaces missing `issues:create` via LinearScopesService.
    public static let scope = "read,issues:create"

    /// `actor=user` — default; resources (if written) belong to the authorizing user.
    /// A read-only scope makes the actor choice almost cosmetic, but we pin it for
    /// explicitness (Linear docs default value).
    public static let actor = "user"

    /// GraphQL query to /graphql after token exchange. Returns the workspace identity
    /// for display in the Settings UI. `urlKey` — a short human-readable slug
    /// (e.g. "acme"); `name` — the full workspace name.
    public static let viewerQuery = """
    query LeafViewer {
      viewer {
        id
        organization {
          id
          name
          urlKey
        }
      }
    }
    """

    /// DistributedNotification name, posted on connect/disconnect/refreshDenied.
    /// Listeners: ConnectionsSettings (UI re-render), LinearCollector (Phase 4.2 reload).
    public static let integrationChangedNotificationName = "tech.gundem.leaf.linear-integration-changed"

    /// UserDefaults suite/key for the refresh_token denial flag (Phase 4.2 D3).
    /// Cross-process: kCFPreferencesCurrentApplication — the Agent and main app
    /// share a single suite (`tech.gundem.leaf`).
    public static let userDefaultsSuite = "tech.gundem.leaf"
    public static let refreshDeniedFlagKey = "linear.refreshDenied"
}
