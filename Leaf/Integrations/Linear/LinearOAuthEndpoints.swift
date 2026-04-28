//
//  LinearOAuthEndpoints.swift
//  Leaf
//
//  Phase 4.1 — endpoint URLs + GraphQL viewer query.
//  Verified против https://linear.app/developers/oauth-2-0-authentication 2026-04-28.
//

import Foundation

nonisolated enum LinearOAuthEndpoints {
    /// Authorize URL — browser flow начинается здесь.
    static let authorize = URL(string: "https://linear.app/oauth/authorize")!
    /// Token endpoint — POST для grant_type=authorization_code и refresh_token.
    static let token = URL(string: "https://api.linear.app/oauth/token")!
    /// GraphQL endpoint — single viewer query на этапе fetchingWorkspace.
    static let graphql = URL(string: "https://api.linear.app/graphql")!

    /// Loopback redirect URI. Linear требует exact-match (port обязателен,
    /// не variable per RFC 8252 — Linear доки явно показывают port в example).
    /// При изменении порта обнови redirect URI в Linear OAuth app config.
    static let redirectHost = "127.0.0.1"
    static let redirectPort: UInt16 = 47823
    static let redirectPath = "/callback"
    static var redirectURI: String { "http://\(redirectHost):\(redirectPort)\(redirectPath)" }

    /// Минимальный read-only scope. Определён в Linear docs как always-present.
    static let scope = "read"

    /// `actor=user` — default; ресурсы (если пишутся) принадлежат authorizing user.
    /// Read-only scope делает actor выбор почти косметическим, но фиксируем для
    /// явности (Linear docs default value).
    static let actor = "user"

    /// GraphQL query на /graphql после token exchange. Возвращает workspace identity
    /// для отображения в Settings UI. `urlKey` — короткий human-readable slug
    /// (e.g. "acme"); `name` — полное имя workspace.
    static let viewerQuery = """
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
}
