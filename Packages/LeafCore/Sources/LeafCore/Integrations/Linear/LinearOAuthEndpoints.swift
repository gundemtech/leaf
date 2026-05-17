//
//  LinearOAuthEndpoints.swift
//  LeafCore
//
//  Phase 4.1 — endpoint URLs + GraphQL viewer query.
//  Phase 4.2 — moved из Leaf/ в LeafCore для cross-binary access (Agent + main app).
//  Verified против https://linear.app/developers/oauth-2-0-authentication 2026-04-28.
//

import Foundation

// swiftlint:disable force_unwrapping
// Reason: compile-time-constant URL literals (`URL(string: "https://...")`) never
// fail to parse — `!` is a static guarantee, not a runtime risk.

public enum LinearOAuthEndpoints {
    /// Authorize URL — browser flow начинается здесь.
    public static let authorize = URL(string: "https://linear.app/oauth/authorize")!
    /// Token endpoint — POST для grant_type=authorization_code и refresh_token.
    public static let token = URL(string: "https://api.linear.app/oauth/token")!
    /// GraphQL endpoint — single viewer query на этапе fetchingWorkspace,
    /// и (Phase 4.2) issues polling в LinearCollector.
    public static let graphql = URL(string: "https://api.linear.app/graphql")!

    /// Loopback redirect URI. Linear требует exact-match (port обязателен,
    /// не variable per RFC 8252 — Linear доки явно показывают port в example).
    /// При изменении порта обнови redirect URI в Linear OAuth app config.
    public static let redirectHost = "127.0.0.1"
    public static let redirectPort: UInt16 = 47823
    public static let redirectPath = "/callback"
    public static var redirectURI: String { "http://\(redirectHost):\(redirectPort)\(redirectPath)" }

    /// Минимальный read-only scope. Определён в Linear docs как always-present.
    public static let scope = "read"

    /// `actor=user` — default; ресурсы (если пишутся) принадлежат authorizing user.
    /// Read-only scope делает actor выбор почти косметическим, но фиксируем для
    /// явности (Linear docs default value).
    public static let actor = "user"

    /// GraphQL query на /graphql после token exchange. Возвращает workspace identity
    /// для отображения в Settings UI. `urlKey` — короткий human-readable slug
    /// (e.g. "acme"); `name` — полное имя workspace.
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

    /// DistributedNotification name, постится при connect/disconnect/refreshDenied.
    /// Слушают: ConnectionsSettings (UI re-render), LinearCollector (Phase 4.2 reload).
    public static let integrationChangedNotificationName = "tech.gundem.leaf.linear-integration-changed"

    /// UserDefaults suite/key для refresh_token denial flag (Phase 4.2 D3).
    /// Cross-process: kCFPreferencesCurrentApplication — Agent и main app
    /// разделяют один suite (`tech.gundem.leaf`).
    public static let userDefaultsSuite = "tech.gundem.leaf"
    public static let refreshDeniedFlagKey = "linear.refreshDenied"
}
// swiftlint:enable force_unwrapping
