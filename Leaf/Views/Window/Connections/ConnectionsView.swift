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
private let providerTitleCapHeightRatio: CGFloat = 0.71
/// LeafType.title.medium font size — kept inline to compute the alignment
/// guide; if the section title token changes, update here too.
private let providerTitleFontSize: CGFloat = 22

struct ConnectionsView: View {
    @Environment(LinearOAuthService.self) private var linearOAuth
    @Environment(GitHubOAuthService.self) private var githubOAuth
    @Environment(SlackOAuthService.self) private var slackOAuth
    // MARK: requires GitHubScopesReader env injection (Task 21)
    @Environment(GitHubScopesReader.self) private var scopesReader
    // MARK: requires SlackScopesReader env injection (Phase Track-3 D3 / Task 18)
    @Environment(SlackScopesReader.self) private var slackScopes
    // Track-6 P4 — Google Calendar OAuth row (Task 18). No companion ScopesReader:
    // Google scope is a single fixed value (`calendar.readonly`) negotiated at
    // OAuth time; there's no incremental-scope drift to surface like GitHub/Slack.
    @Environment(GoogleCalendarOAuthService.self) private var googleCalendarOAuth

    @State private var nowTick: Date = Date()
    private let countdownTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Cached parse of `integrations.scope` for `provider = github`. Used by
    /// the GitHub Scopes section to compute granted vs missing optional —
    /// `GitHubScopesReader` only exposes `missing` for required-core (per its
    /// state contract), so optional-scope status needs a separate read.
    /// Refreshed on `.onAppear` and on the `integrationChangedNotificationName`
    /// distributed notification (mirrors how `GitHubScopesReader` itself
    /// invalidates). Empty set is the safe default — section degrades to
    /// "all missing" rather than crashing if the read fails.
    @State private var grantedGitHubScopes: Set<String> = []

    /// Same pattern for Slack — D3 Task 20. `SlackScopesReader` exposes only
    /// missing-core; optional-scope rendering needs the granted set independently.
    @State private var grantedSlackScopes: Set<String> = []

    /// Per-scope explainer copy (English MVP). Surfaces the user-facing reason
    /// each missing scope matters next to the inline warning banner. Unknown
    /// scopes (`repo`, `read:user` baseline) stay silent — they're table-stakes
    /// not feature gates, so an empty entry signals "no banner".
    private static let scopeExplainer: [String: String] = [
        "read:org": "Required to detect Organization context for audit log and project membership.",
        "read:project": "Required to track ProjectsV2 board activity (cards, iterations, fields).",
        "security_events": "Recommended: surfaces secret-scanning, code-scanning, and Dependabot alerts.",
        "read:audit_log": "Recommended: tracks admin actions on your GitHub Organization."
    ]

    /// Per-scope explainer copy для Slack — D3 Task 20. Только missing-core
    /// scope'ы получают per-scope LeafBanner.warning; missing-optional —
    /// single subtle hint, без объяснения per scope.
    private static let slackScopeExplainer: [String: String] = [
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

    private var header: some View {
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

    // MARK: - Provider blocks

    private var providerBlocks: some View {
        VStack(alignment: .leading, spacing: LeafSpace.xl) {
            providerSection(
                logoAsset: "leaf-brand-linear",
                logoTileColor: .black,
                title: "Linear",
                description: "Read-only access — issue activity (assigned, updated, completed) into your local timeline."
            ) {
                LeafCard(variant: .raised, padding: .regular) {
                    linearContent
                }
            }

            providerSection(
                logoAsset: "leaf-brand-github",
                logoTileColor: .white,
                title: "GitHub",
                description: "Read-only access — self-authored events (commits, PRs, issues, reviews) into your local timeline."
            ) {
                VStack(alignment: .leading, spacing: LeafSpace.lg) {
                    LeafCard(variant: .raised, padding: .regular) {
                        githubContent
                    }
                    if shouldShowScopesSection {
                        scopesSection
                    }
                }
            }

            providerSection(
                logoAsset: "leaf-brand-slack",
                logoTileColor: .white,
                title: "Slack",
                description: "Read-only access — self-authored message counts per channel and huddle minutes into your local timeline."
            ) {
                VStack(alignment: .leading, spacing: LeafSpace.lg) {
                    LeafCard(variant: .raised, padding: .regular) {
                        slackContent
                    }
                    if shouldShowSlackScopesSection {
                        slackScopesSection
                    }
                }
            }

            // Track-6 P4 — Google Calendar row. SF Symbol fallback (no
            // Asset-Catalog brand glyph shipped yet) on a white tile to match
            // GitHub/Slack contrast; Google's brand mark requires distribution
            // sign-off so we surface a neutral system symbol for MVP.
            providerSectionSymbol(
                systemSymbol: "calendar.circle.fill",
                logoTileColor: .white,
                symbolTint: Color(red: 0.18, green: 0.41, blue: 0.92),
                title: "Google Calendar",
                description: "Read-only access — meeting metadata (titles, times, attendee counts) into your local timeline. Attendee identities and event bodies stay on Google."
            ) {
                LeafCard(variant: .raised, padding: .regular) {
                    googleCalendarContent
                }
            }
        }
    }

    /// Mirrors LeafSection (Organism O2) layout but prepends a 28pt brand
    /// logo on a rounded tile to the title row, top-aligned to the title's
    /// cap-top via `.providerLogoAnchor` (matches Home hero icon pattern).
    ///
    /// `logoTileColor` is per-provider because each brand logo file ships in
    /// a specific contrast variant: GitHub black Octocat + Slack 4-colour glyph
    /// → white tile; Linear ships as white-on-dark variant → black tile.
    /// Each on its canonical brand surface; nil = no tile (raw logo).
    private func providerSection<Content: View>(
        logoAsset: String,
        logoTileColor: Color?,
        title: String,
        description: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            HStack(alignment: .providerLogoAnchor, spacing: LeafSpace.sm) {
                providerLogo(asset: logoAsset, tileColor: logoTileColor)
                    .alignmentGuide(.providerLogoAnchor) { $0[.top] }
                VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                    Text(title)
                        .font(LeafSectionTokens.titleFont)
                        .foregroundStyle(LeafColor.text.primary)
                        .alignmentGuide(.providerLogoAnchor) { d in
                            d[.firstTextBaseline] - providerTitleFontSize * providerTitleCapHeightRatio
                        }
                    Text(description)
                        .font(LeafSectionTokens.descriptionFont)
                        .foregroundStyle(LeafColor.text.secondary)
                }
            }
            content()
        }
    }

    /// 28pt total dimension. With tile: RoundedRectangle (LeafRadius.sm) in
    /// `tileColor` + 20pt inner logo centered (~4pt padding each side).
    /// `tileColor: nil` → logo at full 28pt without tile.
    @ViewBuilder
    private func providerLogo(asset: String, tileColor: Color?) -> some View {
        let outer: CGFloat = 28                   // raw — between LeafIconSize.lg (24) and .xl (32)
        let inner: CGFloat = 20                   // logo glyph inside tile
        if let tileColor {
            ZStack {
                RoundedRectangle(cornerRadius: LeafRadius.sm, style: .continuous)
                    .fill(tileColor)
                Image(asset)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: inner, height: inner)
            }
            .frame(width: outer, height: outer)
        } else {
            Image(asset)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: outer, height: outer)
        }
    }

    // MARK: - Provider section (SF Symbol variant — Track-6 P4)

    /// Mirror of `providerSection` but with an SF Symbol glyph instead of an
    /// Asset-Catalog image. Used for Google Calendar where we don't yet ship
    /// a brand-cleared image asset. `symbolTint` colors the glyph itself
    /// (foregroundStyle on the SF Symbol); the tile background uses
    /// `logoTileColor` like the asset variant.
    private func providerSectionSymbol<Content: View>(
        systemSymbol: String,
        logoTileColor: Color?,
        symbolTint: Color,
        title: String,
        description: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            HStack(alignment: .providerLogoAnchor, spacing: LeafSpace.sm) {
                providerSymbol(systemSymbol: systemSymbol, tileColor: logoTileColor, tint: symbolTint)
                    .alignmentGuide(.providerLogoAnchor) { $0[.top] }
                VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                    Text(title)
                        .font(LeafSectionTokens.titleFont)
                        .foregroundStyle(LeafColor.text.primary)
                        .alignmentGuide(.providerLogoAnchor) { d in
                            d[.firstTextBaseline] - providerTitleFontSize * providerTitleCapHeightRatio
                        }
                    Text(description)
                        .font(LeafSectionTokens.descriptionFont)
                        .foregroundStyle(LeafColor.text.secondary)
                }
            }
            content()
        }
    }

    /// Same 28pt-outer / 20pt-inner sizing as `providerLogo` so the new row
    /// aligns vertically with the asset-backed rows (Linear/GitHub/Slack).
    @ViewBuilder
    private func providerSymbol(systemSymbol: String, tileColor: Color?, tint: Color) -> some View {
        let outer: CGFloat = 28
        let inner: CGFloat = 20
        if let tileColor {
            ZStack {
                RoundedRectangle(cornerRadius: LeafRadius.sm, style: .continuous)
                    .fill(tileColor)
                Image(systemName: systemSymbol)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(tint)
                    .frame(width: inner, height: inner)
            }
            .frame(width: outer, height: outer)
        } else {
            Image(systemName: systemSymbol)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(tint)
                .frame(width: outer, height: outer)
        }
    }

    // MARK: - Google Calendar (Track-6 P4)

    @ViewBuilder
    private var googleCalendarContent: some View {
        switch googleCalendarOAuth.state {
        case .notConnected:
            disconnectedBlock(
                title: "Not connected",
                description: "Sign in with Google to share meeting metadata (titles, times, attendee counts) into your local timeline.",
                ctaTitle: "Connect Google Calendar",
                action: { Task { await googleCalendarOAuth.connect() } }
            )
        case .authorizing, .waitingForCallback, .exchangingToken, .fetchingWorkspace:
            progressBlock(label: googleCalendarProgressLabel)
        case .connected(let workspaceName, let connectedAt):
            connectedBlock(
                title: workspaceName,
                connectedAt: connectedAt,
                action: { googleCalendarOAuth.disconnect() }
            )
        case .reconnectNeeded:
            reconnectBlock(
                description: "Your Google session expired and Leaf can't refresh it automatically. Sign in again to resume polling.",
                ctaTitle: "Reconnect Google Calendar",
                action: { Task { await googleCalendarOAuth.connect() } }
            )
        case .error(let message):
            errorBlock(
                description: message,
                action: { Task { await googleCalendarOAuth.connect() } }
            )
        }
    }

    private var googleCalendarProgressLabel: String {
        switch googleCalendarOAuth.state {
        case .authorizing: "Preparing authorization…"
        case .waitingForCallback: "Waiting for Google approval in browser…"
        case .exchangingToken: "Exchanging token…"
        case .fetchingWorkspace: "Loading primary calendar…"
        default: ""
        }
    }

    // MARK: - Linear

    @ViewBuilder
    private var linearContent: some View {
        switch linearOAuth.state {
        case .notConnected:
            disconnectedBlock(
                title: "Not connected",
                description: "Sign in with Linear to share issue activity into your local timeline.",
                ctaTitle: "Connect Linear",
                action: { Task { await linearOAuth.connect() } }
            )
        case .authorizing, .waitingForCallback, .exchangingToken, .fetchingWorkspace:
            progressBlock(label: linearProgressLabel)
        case .connected(let workspaceName, let connectedAt):
            connectedBlock(
                title: workspaceName,
                connectedAt: connectedAt,
                action: { linearOAuth.disconnect() }
            )
        case .reconnectNeeded:
            reconnectBlock(
                description: "Your Linear session expired and Leaf can't refresh it automatically. Sign in again to resume polling.",
                ctaTitle: "Reconnect Linear",
                action: { Task { await linearOAuth.connect() } }
            )
        case .error(let message):
            errorBlock(
                description: message,
                action: { Task { await linearOAuth.connect() } }
            )
        }
    }

    private var linearProgressLabel: String {
        switch linearOAuth.state {
        case .authorizing: "Preparing authorization…"
        case .waitingForCallback: "Waiting for Linear approval in browser…"
        case .exchangingToken: "Exchanging token…"
        case .fetchingWorkspace: "Loading workspace…"
        default: ""
        }
    }

    // MARK: - GitHub

    @ViewBuilder
    private var githubContent: some View {
        switch githubOAuth.state {
        case .notConnected:
            disconnectedBlock(
                title: "Not connected",
                description: "Sign in with GitHub to share self-authored events into your local timeline.",
                ctaTitle: "Connect GitHub",
                action: { Task { await githubOAuth.connect() } }
            )
        case .requestingDeviceCode:
            progressBlock(label: "Requesting device code…")
        case .awaitingAuthorization(let userCode, let verificationURI, let expiresAt):
            githubDeviceFlowBlock(userCode: userCode, verificationURI: verificationURI, expiresAt: expiresAt)
        case .exchangingToken, .fetchingViewer:
            progressBlock(label: githubProgressLabel)
        case .connected(let login, let connectedAt):
            connectedBlock(
                title: login,
                connectedAt: connectedAt,
                action: { githubOAuth.disconnect() }
            )
        case .connectedScopeOutdated(let login, let connectedAt, _):
            // Phase Track-3 D2 / Task 19 — render header identical to `.connected`
            // (login + connected timestamp + Disconnect). The Scopes section
            // rendered alongside (`scopesSection`) carries the missing-scope
            // banners + Re-authorize CTA, so the connection block itself stays
            // a clean status pill. Re-auth pressure is also surfaced proactively
            // by the Home banner (Task 18) and sidebar red dot (Task 20).
            connectedBlock(
                title: login,
                connectedAt: connectedAt,
                action: { githubOAuth.disconnect() }
            )
        case .reconnectNeeded:
            reconnectBlock(
                description: "Your GitHub session expired and Leaf can't refresh it automatically. Sign in again to resume polling.",
                ctaTitle: "Reconnect GitHub",
                action: { Task { await githubOAuth.connect() } }
            )
        case .error(let message):
            errorBlock(
                description: message,
                action: { Task { await githubOAuth.connect() } }
            )
        }
    }

    private var githubProgressLabel: String {
        switch githubOAuth.state {
        case .exchangingToken: "Exchanging token…"
        case .fetchingViewer: "Loading GitHub identity…"
        default: ""
        }
    }

    private func githubDeviceFlowBlock(userCode: String, verificationURI: URL, expiresAt: Date) -> some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("Enter this code on GitHub")
                .font(LeafType.title.small)
                .foregroundStyle(LeafColor.text.primary)
            Text(userCode)
                .font(LeafType.mono.large)
                .foregroundStyle(LeafColor.text.primary)
                .textSelection(.enabled)
            HStack(spacing: LeafSpace.sm) {
                LeafButton(
                    "Open in browser",
                    variant: .primary,
                    size: .sm,
                    action: { NSWorkspace.shared.open(verificationURI) }
                )
                LeafButton(
                    "Copy code",
                    variant: .secondary,
                    size: .sm,
                    action: {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(userCode, forType: .string)
                    }
                )
                LeafButton(
                    "Cancel",
                    variant: .ghost,
                    size: .sm,
                    action: { githubOAuth.cancel() }
                )
            }
            Text(countdownLabel(expiresAt: expiresAt))
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.tertiary)
        }
    }

    // MARK: - Slack

    @ViewBuilder
    private var slackContent: some View {
        switch slackOAuth.state {
        case .notConnected:
            disconnectedBlock(
                title: "Not connected",
                description: "Sign in with Slack to capture self-authored message counts and huddle minutes into your local timeline.",
                ctaTitle: "Connect Slack",
                action: { Task { await slackOAuth.connect() } }
            )
        case .authorizing, .waitingForCallback, .exchangingToken, .fetchingWorkspace:
            progressBlock(label: slackProgressLabel)
        case .connected(let workspaceName, let connectedAt):
            connectedBlock(
                title: workspaceName,
                connectedAt: connectedAt,
                action: { slackOAuth.disconnect() }
            )
        case .connectedScopeOutdated(let workspaceName, let connectedAt, _):
            // Phase Track-3 D3 — Tasks 19-21 add the dedicated re-auth banner /
            // missing-scopes detail UI. Until then surface as plain connected so
            // the substrate ships без UI regression.
            connectedBlock(
                title: workspaceName,
                connectedAt: connectedAt,
                action: { slackOAuth.disconnect() }
            )
        case .reconnectNeeded:
            reconnectBlock(
                description: "Your Slack session expired and Leaf can't refresh it automatically. Sign in again to resume polling.",
                ctaTitle: "Reconnect Slack",
                action: { Task { await slackOAuth.connect() } }
            )
        case .error(let message):
            errorBlock(
                description: message,
                action: { Task { await slackOAuth.connect() } }
            )
        }
    }

    private var slackProgressLabel: String {
        switch slackOAuth.state {
        case .authorizing: "Preparing authorization…"
        case .waitingForCallback: "Waiting for Slack approval in browser…"
        case .exchangingToken: "Exchanging token…"
        case .fetchingWorkspace: "Loading workspace…"
        default: ""
        }
    }

    // MARK: - Shared blocks

    private func disconnectedBlock(
        title: String,
        description: String,
        ctaTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text(title)
                .font(LeafType.title.small)
                .foregroundStyle(LeafColor.text.primary)
            Text(description)
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.secondary)
            LeafButton(ctaTitle, variant: .primary, size: .md, action: action)
        }
    }

    private func progressBlock(label: String) -> some View {
        HStack(spacing: LeafSpace.sm) {
            ProgressView().controlSize(.small)
            Text(label)
                .font(LeafType.body.regular)
                .foregroundStyle(LeafColor.text.secondary)
        }
    }

    private func connectedBlock(
        title: String,
        connectedAt: Date,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: LeafSpace.md) {
            LeafDot(tone: .success, size: .md)
                .padding(.top, LeafSpace.xs)   // align with title baseline (xs = 4pt nudge)
            VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                Text(title)
                    .font(LeafType.title.small)
                    .foregroundStyle(LeafColor.text.primary)
                Text("\(connectedLabel(connectedAt: connectedAt)) · Polls every 5 min")
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.tertiary)
            }
            Spacer()
            LeafButton("Disconnect", variant: .destructive, size: .sm, action: action)
        }
    }

    private func reconnectBlock(
        description: String,
        ctaTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            LeafIconLabel(
                icon: .asset(LeafIcons.status.warning),
                title: "Reconnect needed",
                iconTint: LeafColor.status.warning,
                titleStyle: LeafType.title.small
            )
            Text(description)
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.secondary)
            LeafButton(ctaTitle, variant: .primary, size: .md, action: action)
        }
    }

    private func errorBlock(
        description: String,
        action: @escaping () -> Void
    ) -> some View {
        LeafBanner(
            tone: .danger,
            title: "Couldn't authenticate",
            description: description,
            ctaTitle: "Try again",
            onCTA: action
        )
    }

    // MARK: - Labels

    /// `RelativeDateTimeFormatter` для свежей даты возвращает "in 0 seconds" из-за
    /// nanosecond drift между timestamp создания row и rendered Date(). Под 5s
    /// ставим стабильный лейбл; выше — относительный formatter.
    private func connectedLabel(connectedAt: Date) -> String {
        let elapsed = abs(Date().timeIntervalSince(connectedAt))
        if elapsed < 5 {
            return "Just connected"
        }
        return "Connected \(Self.relativeFormatter.localizedString(for: connectedAt, relativeTo: Date()))"
    }

    /// MM:SS countdown до истечения device_code (RFC 8628 §3.2 expiresIn).
    private func countdownLabel(expiresAt: Date) -> String {
        let remaining = max(0, Int(expiresAt.timeIntervalSince(nowTick)))
        let minutes = remaining / 60
        let seconds = remaining % 60
        if remaining <= 0 {
            return "Code expired — try again."
        }
        return String(format: "Code expires in %d:%02d", minutes, seconds)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    // MARK: - GitHub Scopes section (Task 19)

    /// Render Scopes section under the GitHub block when the connection is
    /// in either `.connected` (informational — granted-only badges, no warnings,
    /// no CTA) OR `.connectedScopeOutdated` (full layout — warnings + CTA).
    /// Skipped for `.notConfigured` / `.unknown` (no GitHub connected) and any
    /// non-connected state of the underlying `githubOAuth` flow.
    private var shouldShowScopesSection: Bool {
        switch scopesReader.state {
        case .connected, .connectedScopeOutdated:
            return true
        case .unknown, .notConfigured:
            return false
        }
    }

    /// Granted scopes intersected with `requested = requiredCore ∪ requiredOptional`.
    /// Used to render the badge matrix. Scopes outside the requested set
    /// (legacy grants) are intentionally excluded — the section only documents
    /// what Leaf asks for, not the full token grant.
    private var currentGranted: Set<String> {
        grantedGitHubScopes
    }

    /// Required-core scopes that are not in `currentGranted`. These render
    /// as red-tone badges + per-scope LeafBanner.warning explainers.
    private var missingCore: Set<String> {
        GitHubScopesService.requiredCore.subtracting(currentGranted)
    }

    /// Required-optional scopes that are not in `currentGranted`. These
    /// render as a single subtle hint line (no per-scope banner — they're
    /// recommended, not blocking).
    private var missingOptional: Set<String> {
        GitHubScopesService.requiredOptional.subtracting(currentGranted)
    }

    /// All scopes Leaf asks for, sorted for stable badge order.
    private var allRequestedScopes: [String] {
        Array(GitHubScopesService.requiredCore.union(GitHubScopesService.requiredOptional)).sorted()
    }

    @ViewBuilder
    private var scopesSection: some View {
        LeafSection(
            title: "Scopes",
            description: "GitHub OAuth scopes Leaf uses to read your activity."
        ) {
            LeafCard(variant: .raised, padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.md) {
                    badgeMatrix
                    if !missingCore.isEmpty {
                        ForEach(Array(missingCore).sorted(), id: \.self) { scope in
                            LeafBanner(
                                tone: .warning,
                                title: scope,
                                description: ConnectionsView.scopeExplainer[scope]
                                    ?? "Required for GitHub integration."
                            )
                        }
                    }
                    if !missingOptional.isEmpty {
                        Text("Recommended scopes not granted: \(missingOptional.sorted().joined(separator: ", "))")
                            .font(LeafType.body.small)
                            .foregroundStyle(LeafColor.text.tertiary)
                    }
                    if !missingCore.isEmpty || !missingOptional.isEmpty {
                        LeafButton(
                            "Re-authorize GitHub",
                            variant: .primary,
                            size: .md,
                            action: {
                                Task {
                                    await githubOAuth.connect(
                                        scopes: GitHubScopesService.requested()
                                    )
                                }
                            }
                        )
                    }
                }
            }
        }
    }

    /// Granted/missing badge grid. Wraps via LazyVGrid `.adaptive` because
    /// the codebase doesn't ship a FlowLayout primitive and a plain HStack
    /// would clip on narrow Connections pane widths. Scope tokens are short
    /// (`repo`, `read:org`, `security_events`) so an adaptive minimum of 110pt
    /// fits 2-3 per row at typical pane widths without truncation.
    @ViewBuilder
    private var badgeMatrix: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 110), spacing: LeafSpace.xs, alignment: .leading)],
            alignment: .leading,
            spacing: LeafSpace.xs
        ) {
            ForEach(allRequestedScopes, id: \.self) { scope in
                let granted = currentGranted.contains(scope)
                let core = GitHubScopesService.requiredCore.contains(scope)
                // LeafBadge ships only `.neutral / .accent / .numeric` — no
                // `.success / .danger` variant in the substrate. Map intent:
                // granted → `.accent` (positive emphasis); missing-core +
                // missing-optional → `.neutral` (the per-scope LeafBanner.warning
                // below carries the criticality cue, so the badge stays calm).
                LeafBadge(
                    text: scope,
                    variant: granted ? .accent : .neutral
                )
                .accessibilityLabel(badgeAccessibilityLabel(scope: scope, granted: granted, core: core))
            }
        }
    }

    private func badgeAccessibilityLabel(scope: String, granted: Bool, core: Bool) -> String {
        if granted {
            return "\(scope), granted"
        }
        return core ? "\(scope), missing required scope" : "\(scope), missing recommended scope"
    }

    /// Reads `integrations.scope` for `provider = github` and parses the
    /// space-separated token list into `grantedGitHubScopes`. Mirrors
    /// `GitHubScopesService.parseScopeString` semantics exactly. Failure path
    /// (no integration row, DB read error) → empty set, which makes the
    /// section render as "all missing" rather than crash. Synchronous because
    /// `Database.readIntegration` is a single-row query and Connections is
    /// already main-thread; we trade trivial latency for an inline path that
    /// avoids a parallel async observable for the same data the reader
    /// already polls.
    private func refreshGrantedGitHubScopes() {
        let parsed = Self.readGrantedGitHubScopes()
        grantedGitHubScopes = parsed
    }

    /// Open the canonical app DB (same defaults as `GitHubOAuthService`),
    /// read the GitHub integration row, parse `scope`. Returns empty set on
    /// any failure. `static` so closure captures don't bind to `self`.
    nonisolated private static func readGrantedGitHubScopes() -> Set<String> {
        do {
            let db = try Database.openForRead(
                at: DatabasePath.defaultURL(),
                config: githubScopesDatabaseConfig(),
                encryption: githubScopesDatabaseEncryption()
            )
            guard let record = try db.readIntegration(provider: .github) else {
                return []
            }
            return parseGitHubScopeString(record.scope)
        } catch {
            return []
        }
    }

    nonisolated private static func githubScopesDatabaseConfig() -> DatabaseConfig {
        #if LEAF_PROD
        return ProdConfigs.database
        #else
        return .weakDefaults
        #endif
    }

    nonisolated private static func githubScopesDatabaseEncryption() -> EncryptionOptions? {
        #if LEAF_PROD
        return EncryptionOptions(
            keyProvider: .callback { @Sendable in
                try FileKeyStore.fetchOrCreate()
            },
            preKeyPragmas: ProdConfigs.sqlcipherPragmasPreKey,
            postKeyPragmas: ProdConfigs.sqlcipherPragmasPostKey
        )
        #else
        return nil
        #endif
    }

    /// Inline copy of `GitHubScopesService.parseScopeString`. Kept local to
    /// avoid a public API expansion just for this view; the LeafCore one is
    /// `internal static` so unreachable from the app target. Splits on both
    /// commas and whitespace because GitHub's token-exchange response uses
    /// comma-separated scope strings, while the legacy `X-OAuth-Scopes`
    /// header form is space-separated.
    nonisolated private static func parseGitHubScopeString(_ raw: String?) -> Set<String> {
        guard let raw else { return [] }
        let parts = raw
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map { String($0) }
            .filter { !$0.isEmpty }
        return Set(parts)
    }

    // MARK: - Slack Scopes section (Phase Track-3 D3 / Task 20)

    /// Mirrors `shouldShowScopesSection` for Slack — section renders when
    /// `slackScopes.state` is either `.connected` (informational matrix, no
    /// banners) or `.connectedScopeOutdated` (warning banners + Re-authorize
    /// CTA). Hidden in `.unknown` / `.notConfigured`.
    private var shouldShowSlackScopesSection: Bool {
        switch slackScopes.state {
        case .connected, .connectedScopeOutdated:
            return true
        case .unknown, .notConfigured:
            return false
        }
    }

    private var currentGrantedSlack: Set<String> {
        grantedSlackScopes
    }

    private var missingSlackCore: Set<String> {
        SlackScopesService.requiredCore.subtracting(currentGrantedSlack)
    }

    private var missingSlackOptional: Set<String> {
        SlackScopesService.requiredOptional.subtracting(currentGrantedSlack)
    }

    private var allRequestedSlackScopes: [String] {
        Array(SlackScopesService.requiredCore
            .union(SlackScopesService.requiredOptional)).sorted()
    }

    @ViewBuilder
    private var slackScopesSection: some View {
        LeafSection(
            title: "Scopes",
            description: "Slack OAuth scopes Leaf uses to read your activity."
        ) {
            LeafCard(variant: .raised, padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.md) {
                    slackBadgeMatrix
                    if !missingSlackCore.isEmpty {
                        ForEach(Array(missingSlackCore).sorted(), id: \.self) { scope in
                            LeafBanner(
                                tone: .warning,
                                title: scope,
                                description: ConnectionsView.slackScopeExplainer[scope]
                                    ?? "Required for Slack integration."
                            )
                        }
                    }
                    if !missingSlackOptional.isEmpty {
                        Text("Recommended scopes not granted: \(missingSlackOptional.sorted().joined(separator: ", "))")
                            .font(LeafType.body.small)
                            .foregroundStyle(LeafColor.text.tertiary)
                    }
                    if !missingSlackCore.isEmpty || !missingSlackOptional.isEmpty {
                        LeafButton(
                            "Re-authorize Slack",
                            variant: .primary,
                            size: .md,
                            action: {
                                Task { await slackOAuth.connect() }
                            }
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var slackBadgeMatrix: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 110), spacing: LeafSpace.xs, alignment: .leading)],
            alignment: .leading,
            spacing: LeafSpace.xs
        ) {
            ForEach(allRequestedSlackScopes, id: \.self) { scope in
                let granted = currentGrantedSlack.contains(scope)
                let core = SlackScopesService.requiredCore.contains(scope)
                LeafBadge(
                    text: scope,
                    variant: granted ? .accent : .neutral
                )
                .accessibilityLabel(badgeAccessibilityLabel(scope: scope, granted: granted, core: core))
            }
        }
    }

    /// Mirrors `refreshGrantedGitHubScopes` — reads `integrations.scope` for
    /// `provider = slack` synchronously on main thread (single-row query).
    private func refreshGrantedSlackScopes() {
        grantedSlackScopes = Self.readGrantedSlackScopes()
    }

    nonisolated private static func readGrantedSlackScopes() -> Set<String> {
        do {
            let db = try Database.openForRead(
                at: DatabasePath.defaultURL(),
                config: githubScopesDatabaseConfig(),
                encryption: githubScopesDatabaseEncryption()
            )
            guard let record = try db.readIntegration(provider: .slack) else {
                return []
            }
            return parseGitHubScopeString(record.scope)
        } catch {
            return []
        }
    }
}
