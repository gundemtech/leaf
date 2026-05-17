//
//  ConnectionsView.swift
//  Track 2 / D3 — Connections screen on D1 substrate. Folds the Form-based
//  ConnectionsSettings (Phase 4.1 artifact at Leaf/Views/ConnectionsSettings.swift)
//  inline. 3 provider sections (Linear / GitHub / Slack) each rendered as
//  LeafSection (title + description) wrapping a LeafCard.raised whose content
//  switches on `service.state`. Native Form chrome — gone. Per-provider
//  state-machine UX preserved 1:1 — only the visual chrome migrated.
//
//  OAuth flow trigger preserved: `Task { await service.connect() }` opens
//  the system browser (or Slack relay loopback). No sheet redesign in D3.
//
//  Phase 2.3.C.3 + C.4 — primary type holds storage + body + header only.
//  Per-section UI moved to co-located extension files:
//    +ProviderSections.swift  — providerBlocks + logo/symbol helpers
//    +Providers.swift         — per-provider content (GoogleCal / Linear / GitHub / Slack)
//    +SharedBlocks.swift      — disconnected / progress / connected / reconnect / error + labels
//    +GitHubScopes.swift      — GitHub scope diagnostics + integrations-row read
//    +SlackScopes.swift       — Slack scope diagnostics
//

import SwiftUI
import Combine
import LeafCore
#if LEAF_PROD
import LeafCorePrivate
#endif

/// Pin provider logo top to the title's cap-top (visual top edge of glyphs),
/// not the title-frame top — frame includes leading. Mirrors the Home hero
/// `heroIconAnchor` pattern; recomputed per-screen because title font size
/// differs (Connections uses LeafType.title.medium = 22pt).
extension VerticalAlignment {
    private struct ProviderLogoAnchor: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[VerticalAlignment.top]
        }
    }
    static let providerLogoAnchor = VerticalAlignment(ProviderLogoAnchor.self)
}

/// SF Pro Display semibold cap-height ratio (empirical) — same constant as
/// HomeView.heroTitleCapHeightRatio. Title cap-top ≈ baseline − fontSize × ratio.
let providerTitleCapHeightRatio: CGFloat = 0.71
/// LeafType.title.medium font size — kept inline to compute the alignment
/// guide; if the section title token changes, update here too.
let providerTitleFontSize: CGFloat = 22

struct ConnectionsView: View {
    @Environment(LinearOAuthService.self) var linearOAuth
    @Environment(GitHubOAuthService.self) var githubOAuth
    @Environment(SlackOAuthService.self) var slackOAuth
    // MARK: requires GitHubScopesReader env injection (Task 21)
    @Environment(GitHubScopesReader.self) var scopesReader
    // MARK: requires SlackScopesReader env injection (Phase Track-3 D3 / Task 18)
    @Environment(SlackScopesReader.self) var slackScopes
    // Track-6 P4 — Google Calendar OAuth row (Task 18). No companion ScopesReader:
    // Google scope is a single fixed value (`calendar.readonly`) negotiated at
    // OAuth time; there's no incremental-scope drift to surface like GitHub/Slack.
    @Environment(GoogleCalendarOAuthService.self) var googleCalendarOAuth

    @State var nowTick = Date()
    let countdownTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Cached parse of `integrations.scope` for `provider = github`. Used by
    /// the GitHub Scopes section to compute granted vs missing optional —
    /// `GitHubScopesReader` only exposes `missing` for required-core (per its
    /// state contract), so optional-scope status needs a separate read.
    /// Refreshed on `.onAppear` and on the `integrationChangedNotificationName`
    /// distributed notification (mirrors how `GitHubScopesReader` itself
    /// invalidates). Empty set is the safe default — section degrades to
    /// "all missing" rather than crashing if the read fails.
    @State var grantedGitHubScopes: Set<String> = []

    /// Same pattern for Slack — D3 Task 20. `SlackScopesReader` exposes only
    /// missing-core; optional-scope rendering needs the granted set independently.
    @State var grantedSlackScopes: Set<String> = []

    /// Per-scope explainer copy (English MVP). Surfaces the user-facing reason
    /// each missing scope matters next to the inline warning banner. Unknown
    /// scopes (`repo`, `read:user` baseline) stay silent — they're table-stakes
    /// not feature gates, so an empty entry signals "no banner".
    static let scopeExplainer: [String: String] = [
        "read:org": "Required to detect Organization context for audit log and project membership.",
        "read:project": "Required to track ProjectsV2 board activity (cards, iterations, fields).",
        "security_events": "Recommended: surfaces secret-scanning, code-scanning, and Dependabot alerts.",
        "read:audit_log": "Recommended: tracks admin actions on your GitHub Organization."
    ]

    /// Per-scope explainer copy для Slack — D3 Task 20. Только missing-core
    /// scope'ы получают per-scope LeafBanner.warning; missing-optional —
    /// single subtle hint, без объяснения per scope.
    static let slackScopeExplainer: [String: String] = [
        "users:read": "Required to resolve usernames and identify self-authored messages.",
        "users.profile:read": "Required to read your profile (status, presence) for huddle and Focus integration.",
        "search:read": "Required to find your messages and files for per-action attribution.",
        "channels:history": "Required to read public-channel message history you posted to.",
        "groups:history": "Required to read private-channel message history you posted to.",
        "im:history": "Required to read DM history you participated in.",
        "mpim:history": "Required to read group-DM history you participated in.",
        "dnd:read": "Required to capture Do Not Disturb intervals as Focus context.",
        "files:read": "Required to track files you uploaded for activity attribution."
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LeafSpace.xxl) {
                header
                providerBlocks
            }
            .padding(LeafSpace.xxl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            linearOAuth.reload()
            githubOAuth.reload()
            slackOAuth.reload()
            googleCalendarOAuth.reload()
            refreshGrantedGitHubScopes()
            refreshGrantedSlackScopes()
        }
        .onReceive(countdownTimer) { now in
            nowTick = now
        }
        .onReceive(DistributedNotificationCenter.default().publisher(
            for: NSNotification.Name(GitHubOAuthEndpoints.integrationChangedNotificationName))
        ) { _ in
            refreshGrantedGitHubScopes()
        }
        .onReceive(DistributedNotificationCenter.default().publisher(
            for: NSNotification.Name(SlackOAuthEndpoints.integrationChangedNotificationName))
        ) { _ in
            refreshGrantedSlackScopes()
        }
    }

    // MARK: - Header

    var header: some View {
        VStack(alignment: .leading, spacing: LeafSpace.sm) {
            Text("CONNECTIONS")
                .leafSectionLabel()
                .foregroundStyle(LeafColor.text.tertiary)
            Text("Connections")
                .font(LeafType.title.large)
                .foregroundStyle(LeafColor.text.primary)
            Text("Linear, GitHub, Slack, Google Calendar — sources of truth Leaf observes on your behalf. Data stays on your device.")
                .font(LeafType.body.regular)
                .foregroundStyle(LeafColor.text.secondary)
        }
    }
}
