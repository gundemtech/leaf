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

    @State private var nowTick: Date = Date()
    private let countdownTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

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
        }
        .onReceive(countdownTimer) { now in
            nowTick = now
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
            Text("Linear, GitHub, Slack — sources of truth Leaf observes on your behalf. Data stays on your device.")
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
                LeafCard(variant: .raised, padding: .regular) {
                    githubContent
                }
            }

            providerSection(
                logoAsset: "leaf-brand-slack",
                logoTileColor: .white,
                title: "Slack",
                description: "Read-only access — self-authored message counts per channel and huddle minutes into your local timeline."
            ) {
                LeafCard(variant: .raised, padding: .regular) {
                    slackContent
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
}
