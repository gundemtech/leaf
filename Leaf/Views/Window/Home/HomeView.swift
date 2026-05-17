//
//  HomeView.swift
//  Track 2 / D2 — Home screen. 4-section compact IA:
//
//    1. Hero (current state) — single LeafType.title.large + caption row
//       with inline metrics. Three states: active session / idle / no-data.
//    2. Live Presence — LivePresenceWidget on D1 organisms.
//    3. Today summary — LeafMetricAmbient (focus today) + middot inline
//       metrics row + 3 provider rows (Linear / GitHub / Slack) as
//       LeafListRow.
//    4. Recent sessions — RecentSessionsBlock on D1 organisms.
//
//  State-machine UX (InsightsReader.State):
//    .loading        → ProgressView centered in hero region (no shimmer).
//    .notConfigured  → Full-page LeafEmptyState + 'Open Connections' CTA.
//    .empty          → Full-page LeafEmptyState (no CTA).
//    .error          → LeafBanner.danger at top + 'Try again' CTA.
//    .loaded         → Full 4-section render below.
//
//  Zero-data shape: when a loaded snapshot has no recent sessions and
//  no presence and no focus, sections 2/3/4 collapse — Hero says
//  'Leaf is listening'. Symmetric degradation.
//

import SwiftUI
import LeafCore

private let knownLinearPrefixesForHero: Set<String> = ["LEAF"]

/// Hero app-icon size — 36pt. С `heroIconAnchor` (top = title cap-top) icon
/// верхней гранью лежит на линии cap-top'а заголовка, нижней — на середине
/// caption. Не входит в LeafIconSize tokens (.xl = 32pt) — hero единственный
/// consumer 36pt.
private let heroIconSize: CGFloat = 36

/// Bleached leaf-green for cosmetic accent tints (provider row icons,
/// RIGHT NOW column headers). `accent.subtle` в dark mode = 35%-alpha
/// dark-green fill — для foreground tint'а нечитаем. Используем
/// primary с opacity'ом — тот же hue, мягче читается.
extension Color {
    static var leafAccentBleached: Color { LeafColor.accent.primary.opacity(0.6) }
}

/// Custom alignment guide — пинит icon top к title cap-top, не center-to-center.
/// Title frame включает leading выше cap-line'а (для 28pt SF Pro Display
/// semibold ≈ 7pt сверху над «T»), поэтому icon center = title frame center
/// визуально ставит squircle выше cap-line'а. Cap-top считаем как
/// `firstTextBaseline - capHeight`; capHeight ≈ 0.71 от font size для SF Pro
/// Display semibold (Apple metrics; 0.71 — empirical, не доку из Apple).
extension VerticalAlignment {
    private struct HeroIconAnchor: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[VerticalAlignment.top]
        }
    }
    static let heroIconAnchor = VerticalAlignment(HeroIconAnchor.self)
}

/// Cap-height ratio для SF Pro Display semibold — empirical.
private let heroTitleCapHeightRatio: CGFloat = 0.71

/// Hero caption fallback truncation when no Linear ID matches the active
/// session's contextLabel — caps at this many chars before middle-truncating
/// (window titles get long fast: "leaf — D1 Design finish — caffeinate ◂…").
/// Tuned so the caption reads cleanly on the default window's hero region
/// without bleeding into next line.
private let heroContextMaxLength: Int = 40

struct HomeView: View {
    @Environment(InsightsReader.self) private var reader
    @Environment(WindowState.self) private var windowState
    // MARK: requires GitHubScopesReader env injection (Task 21)
    @Environment(GitHubScopesReader.self) private var scopesReader
    @Environment(GitHubOAuthService.self) private var githubOAuth
    // MARK: requires SlackScopesReader env injection (Phase Track-3 D3 / Task 18)
    @Environment(SlackScopesReader.self) private var slackScopes
    @Environment(SlackOAuthService.self) private var slackOAuth

    /// Session-local dismiss flag for the proactive GitHub re-auth banner.
    /// Persisted across the same launch via UserDefaults keyed by
    /// `AppSessionID.current` so a fresh launch (new UUID) re-shows the banner.
    @State private var reauthBannerDismissed = false
    /// Same per-launch dismiss pattern, separate key — Slack banner is
    /// independent of GitHub banner; dismissing one must not silence the other.
    @State private var slackReauthBannerDismissed = false

    private static let reauthBannerDismissKey = "github.reauth.bannerDismissedSessionID"
    private static let slackReauthBannerDismissKey = "slack.reauth.bannerDismissedSessionID"

    private var shouldShowReauthBanner: Bool {
        guard !reauthBannerDismissed else { return false }
        let saved = UserDefaults.standard.string(forKey: Self.reauthBannerDismissKey)
        return saved != AppSessionID.current
    }

    private var shouldShowSlackReauthBanner: Bool {
        guard !slackReauthBannerDismissed else { return false }
        let saved = UserDefaults.standard.string(forKey: Self.slackReauthBannerDismissKey)
        return saved != AppSessionID.current
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LeafSpace.xl) {
                if case let .connectedScopeOutdated(missing) = scopesReader.state, shouldShowReauthBanner {
                    reauthBanner(missingCount: missing.count)
                }

                if case let .connectedScopeOutdated(missing) = slackScopes.state, shouldShowSlackReauthBanner {
                    slackReauthBanner(missingCount: missing.count)
                }

                switch reader.state {
                case .loading:
                    LoadingScaffold()
                case .notConfigured(let msg):
                    notConfiguredFullPage(msg)
                case .empty(let msg):
                    emptyFullPage(msg)
                case .error(let msg):
                    errorBanner(msg)
                case .loaded(let snapshot, _):
                    HomeContent(snapshot: snapshot)
                }
            }
            .padding(LeafSpace.xl)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { reader.refresh() }
    }

    // MARK: - Re-auth banner

    /// Phase Track-3 D2 / Task 18 — proactive GitHub scope-bump banner. Surfaces
    /// the moment Home renders if `GitHubScopesReader` reports outdated scopes
    /// (alpha users grew up before the D2 bump). One CTA «Re-authorize» runs
    /// the full Device Flow with the canonical requested scope set; the
    /// secondary X dismiss stamps `AppSessionID.current` into UserDefaults so
    /// the banner stays gone for the rest of this launch but re-appears on the
    /// next (fresh UUID).
    @ViewBuilder
    private func reauthBanner(missingCount: Int) -> some View {
        LeafBanner(
            tone: .warning,
            title: "GitHub permissions need a refresh",
            description: "\(missingCount) new event type\(missingCount == 1 ? "" : "s") \(missingCount == 1 ? "is" : "are") blocked until you re-authorize.",
            ctaTitle: "Re-authorize",
            onCTA: {
                Task { await githubOAuth.connect(scopes: GitHubScopesService.requested()) }
            },
            onDismiss: {
                UserDefaults.standard.set(AppSessionID.current,
                                          forKey: Self.reauthBannerDismissKey)
                reauthBannerDismissed = true
            }
        )
    }

    /// Phase Track-3 D3 / Task 19 — proactive Slack scope-bump banner. Mirrors
    /// the GitHub banner above byte-for-byte; uses an independent per-launch
    /// `AppSessionID.current` dismiss key so the two providers' banners are
    /// silenced separately. CTA calls `slackOAuth.connect()` — its default
    /// arg path uses `SlackScopesService.requested()` (see Task 10).
    @ViewBuilder
    private func slackReauthBanner(missingCount: Int) -> some View {
        LeafBanner(
            tone: .warning,
            title: "Slack permissions need a refresh",
            description: "\(missingCount) new event type\(missingCount == 1 ? "" : "s") \(missingCount == 1 ? "is" : "are") blocked until you re-authorize.",
            ctaTitle: "Re-authorize Slack",
            onCTA: {
                Task { await slackOAuth.connect() }
            },
            onDismiss: {
                UserDefaults.standard.set(AppSessionID.current,
                                          forKey: Self.slackReauthBannerDismissKey)
                slackReauthBannerDismissed = true
            }
        )
    }

    // MARK: - State-machine renders

    @ViewBuilder
    private func notConfiguredFullPage(_ msg: String) -> some View {
        VStack {
            Spacer()
            LeafEmptyState(
                icon: LeafIcons.object.folderEmpty,
                title: "Connect a provider to enrich Home",
                description: msg,
                ctaTitle: "Open Connections",
                onCTA: { windowState.section = .connections }
            )
            Spacer()
        }
        .frame(minHeight: LeafEmptyStateTokens.centeredMinHeight)
    }

    @ViewBuilder
    private func emptyFullPage(_ msg: String) -> some View {
        VStack {
            Spacer()
            LeafEmptyState(
                icon: LeafIcons.brand.leaf,
                title: "Leaf is listening",
                description: msg
            )
            Spacer()
        }
        .frame(minHeight: LeafEmptyStateTokens.centeredMinHeight)
    }

    @ViewBuilder
    private func errorBanner(_ msg: String) -> some View {
        LeafBanner(
            tone: .danger,
            title: "Couldn't load Home",
            description: msg,
            ctaTitle: "Try again",
            onCTA: { reader.refresh() }
        )
    }
}

// MARK: - Loading scaffold

private struct LoadingScaffold: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.xl) {
            VStack(alignment: .leading, spacing: LeafSpace.xs) {
                Text("Reading recent activity…")
                    .font(LeafType.title.large)
                    .foregroundStyle(LeafColor.text.secondary)
                ProgressView()
                    .controlSize(.small)
            }

            // Muted shape placeholders — no shimmer (D1 §22).
            ForEach(0..<3, id: \.self) { _ in
                LeafCard(padding: .regular) {
                    HStack {
                        Text("—")
                            .font(LeafType.body.regular)
                            .foregroundStyle(LeafColor.text.tertiary)
                        Spacer()
                    }
                }
            }
        }
    }
}

// MARK: - Loaded content

private struct HomeContent: View {
    let snapshot: InsightsSnapshot
    @Environment(RouteCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var coord = coordinator
        NavigationStack(path: $coord.homePath) {
            VStack(alignment: .leading, spacing: LeafSpace.xl) {
                HeroBlock(snapshot: snapshot)

                if !snapshot.presenceState.isEmpty {
                    LivePresenceWidget(snapshot: snapshot.presenceState) { provider in
                        coordinator.pushHomeLayerBProvider(provider)
                    }
                }

                if hasTodayContent {
                    TodaySection(snapshot: snapshot)
                }

                // Track-7 P1 — Surfaces section is always rendered so disabled
                // compact rows are visible from first launch (the "discovery"
                // pattern per spec §3, §8). Other sections gate on data; this
                // one never collapses.
                SurfacesSection(snapshot: snapshot)

                if !snapshot.recentSessions.isEmpty || hasTodayContent || !snapshot.presenceState.isEmpty {
                    RecentSessionsBlock(sessions: snapshot.recentSessions)
                }
            }
            .navigationDestination(for: HomeSurface.self) { surface in
                detail(for: surface)
            }
            .navigationDestination(for: LayerBProvider.self) { provider in
                layerBDetail(for: provider)
            }
        }
    }

    @ViewBuilder
    private func detail(for surface: HomeSurface) -> some View {
        switch surface {
        case .claudeCode:
            ClaudeCodeDetailScreen()
        case .xcode, .ides, .browsers, .zoom, .calendar:
            // P2-P6 will wire these; for P1 show a placeholder.
            VStack {
                Spacer()
                LeafEmptyState(
                    icon: LeafIcons.brand.leaf,
                    title: "\(surface.displayName) detail coming soon",
                    description: "This surface's detail screen lands in a follow-up phase."
                )
                Spacer()
            }
            .frame(minHeight: LeafEmptyStateTokens.centeredMinHeight)
        }
    }

    @ViewBuilder
    private func layerBDetail(for provider: LayerBProvider) -> some View {
        switch provider {
        case .linear:
            LinearDetailScreen()
        case .github, .slack:
            // Placeholder — real screens land in Tasks 7/8 within Track-7 P4.
            VStack {
                Spacer()
                LeafEmptyState(
                    icon: LeafIcons.brand.leaf,
                    title: "\(provider.displayName) detail coming soon",
                    description: "This Layer B drill-down lands in a follow-up task within Track-7 P4."
                )
                Spacer()
            }
            .frame(minHeight: LeafEmptyStateTokens.centeredMinHeight)
        }
    }

    private var hasTodayContent: Bool {
        focusTotal(snapshot) > 0
            || snapshot.linearIssuesTouched > 0
            || snapshot.githubEventsCount > 0
            || snapshot.slackMessagesCount > 0
            || !snapshot.filesTouched.isEmpty   // Track-7 P1 — surface filesTouched
    }
}

// MARK: - Hero

private struct HeroBlock: View {
    let snapshot: InsightsSnapshot

    var body: some View {
        let active = activeSession(snapshot)
        let lastSession = snapshot.recentSessions.first
        let focus = focusTotal(snapshot)

        switch heroState(active: active, lastSession: lastSession, focus: focus) {
        case .active(let session):
            heroLayout(
                bundleID: session.bundleID,
                title: Text(AppNameResolver.shared.displayName(for: session.bundleID))
                    .foregroundStyle(LeafColor.text.primary),
                caption: Text(activeCaption(session: session))
                    .foregroundStyle(LeafColor.text.tertiary)
            )

        case .idle(let session):
            heroLayout(
                bundleID: session.bundleID,
                title: Text("Idle")
                    .foregroundStyle(LeafColor.text.secondary),
                caption: Text("last: \(AppNameResolver.shared.displayName(for: session.bundleID)) · \(relativePast(session.end))")
                    .foregroundStyle(LeafColor.text.tertiary)
            )

        case .noData:
            heroLayout(
                bundleID: nil,
                title: Text("Leaf is listening")
                    .foregroundStyle(LeafColor.text.secondary),
                caption: Text("Connect a provider in Connections to enrich")
                    .foregroundStyle(LeafColor.text.tertiary)
            )
        }
    }

    /// Hero row: real macOS app icon (heroIconSize) ведущим элементом +
    /// VStack(title, caption). Иконка центруется по центру title-line через
    /// custom `VerticalAlignment.heroTitleCenter` — `.center` HStack тянул бы
    /// её к мидпойнту между title и caption (визуально ниже title).
    /// Fallback (bundleID nil или icon не резолвится) — текст без icon-колонки.
    @ViewBuilder
    private func heroLayout(
        bundleID: String?,
        title: Text,
        caption: Text
    ) -> some View {
        if let bundleID,
           let nsImage = AppIconResolver.shared.icon(for: bundleID, size: heroIconSize) {
            HStack(alignment: .heroIconAnchor, spacing: LeafSpace.md) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: heroIconSize, height: heroIconSize)
                    .alignmentGuide(.heroIconAnchor) { $0[.top] }
                VStack(alignment: .leading, spacing: LeafSpace.xs) {
                    title
                        .font(LeafType.title.large)
                        .alignmentGuide(.heroIconAnchor) { d in
                            d[.firstTextBaseline] - 28 * heroTitleCapHeightRatio
                        }
                    caption
                        .font(LeafType.body.small)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: LeafSpace.xs) {
                title.font(LeafType.title.large)
                caption.font(LeafType.body.small)
            }
        }
    }

    private enum HeroState {
        case active(ActivitySession)
        case idle(ActivitySession)
        case noData
    }

    private func heroState(active: ActivitySession?, lastSession: ActivitySession?, focus: TimeInterval) -> HeroState {
        if let active { return .active(active) }
        if let lastSession, focus > 0 { return .idle(lastSession) }
        return .noData
    }

    /// "{Linear ID extracted from contextLabel} · {duration} · idle {N}s"
    /// — drops segments per spec (no Linear ID → fallback trimmed contextLabel
    /// or skip; idle < 5s → omit idle segment).
    private func activeCaption(session: ActivitySession) -> String {
        var parts: [String] = []

        if let context = session.contextLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !context.isEmpty {
            if let linearID = LinearIDExtractor.extract(text: context, knownPrefixes: knownLinearPrefixesForHero) {
                parts.append(linearID)
            } else {
                parts.append(truncateMiddle(context, maxLength: heroContextMaxLength))
            }
        }

        parts.append(formatDuration(session.duration))

        let idleSeconds = max(0, Date().timeIntervalSince(session.end))
        if idleSeconds >= 5 {
            parts.append("idle \(formatDuration(idleSeconds))")
        }

        return parts.joined(separator: " · ")
    }

    private func truncateMiddle(_ s: String, maxLength: Int) -> String {
        guard s.count > maxLength else { return s }
        let head = s.prefix(maxLength / 2)
        let tail = s.suffix(maxLength / 2 - 1)
        return "\(head)…\(tail)"
    }

    private func relativePast(_ date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 60 { return "moments ago" }
        let minutes = Int(elapsed / 60)
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = elapsed / 3600
        if hours < 24 { return "\(Int(hours)) h \(Int(elapsed.truncatingRemainder(dividingBy: 3600) / 60)) min ago" }
        return "earlier today"
    }
}

// MARK: - Today

private struct TodaySection: View {
    let snapshot: InsightsSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("TODAY")
                .leafSectionLabel()
                .foregroundStyle(LeafColor.text.tertiary)

            LeafCard(padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.md) {
                    LeafMetricAmbient(
                        value: focusValue,
                        label: focusLabel,
                        valueTint: LeafColor.accent.primary
                    )

                    if !ambientCaptionFragments.isEmpty {
                        Text(ambientCaptionFragments.joined(separator: " · "))
                            .font(LeafType.body.small)
                            .foregroundStyle(LeafColor.text.tertiary)
                    }

                    if !inlineMetricFragments.isEmpty {
                        LeafDivider()
                        Text(inlineMetricFragments.joined(separator: " · "))
                            .font(LeafType.body.small)
                            .foregroundStyle(LeafColor.text.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    if !providerRows.isEmpty {
                        LeafDivider()
                        VStack(spacing: 0) {
                            ForEach(Array(providerRows.enumerated()), id: \.offset) { idx, row in
                                LeafListRow(
                                    primary: row.text,
                                    leading: { LeafIcon(asset: row.iconAsset, size: .md, tint: .leafAccentBleached) }
                                )
                                if idx < providerRows.count - 1 {
                                    LeafDivider(style: .soft)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Focus value

    private var focusValue: String {
        let focus = focusTotal(snapshot)
        return focus > 0 ? formatDuration(focus) : "—"
    }

    private var focusLabel: String { "Focus today" }

    private var ambientCaptionFragments: [String] {
        var out: [String] = []
        let sessionCount = snapshot.sessions.count
        if sessionCount > 0 {
            out.append("\(sessionCount) session\(sessionCount == 1 ? "" : "s")")
        }
        let streak = snapshot.deepWorkStreak.days
        if streak >= 1 {
            out.append("\(streak)-day streak")
        }
        if let delta = snapshot.weekOverWeekDelta {
            let pct = Int(delta.rounded())
            if abs(pct) >= 2 {
                let arrow = pct > 0 ? "↑" : "↓"
                out.append("\(arrow)\(abs(pct))% vs last week")
            }
        }
        return out
    }

    // MARK: - Inline metrics

    private var inlineMetricFragments: [String] {
        var out: [String] = []
        if let peak = snapshot.peakProductivityHour {
            out.append("Peak around \(String(format: "%02d:00", peak))")
        }
        if snapshot.switchRate > 0 {
            out.append(String(format: "%.1f× switching/hr", snapshot.switchRate))
        }
        if snapshot.aiActiveSeconds > 0 {
            let pct = Int((max(0, min(1, snapshot.aiRatio)) * 100).rounded())
            out.append("\(pct)% with AI")
        }
        // Track-7 P1 — filesTouched wire-up (spec §1 P1 scope).
        let fileCount = snapshot.filesTouched.count
        if fileCount > 0 {
            out.append("\(fileCount) file\(fileCount == 1 ? "" : "s")")
        }
        return out
    }

    // MARK: - Provider rows

    private struct ProviderRow {
        let iconAsset: String
        let text: String
    }

    private var providerRows: [ProviderRow] {
        [linearRow(), githubRow(), slackRow()].compactMap { $0 }
    }

    private func linearRow() -> ProviderRow? {
        var fragments: [String] = ["Linear"]
        if snapshot.linearIssuesTouched > 0 {
            fragments.append("\(snapshot.linearIssuesTouched) touched")
        }
        if let transitions = snapshot.linearTransitions, transitions.completed > 0 {
            fragments.append("\(transitions.completed) done")
        }
        if let rate = snapshot.linearCompletionRate, rate > 0 {
            fragments.append("\(Int((rate * 100).rounded()))% follow-through")
        }
        guard fragments.count > 1 else { return nil }
        return ProviderRow(
            iconAsset: LeafIcons.nav.connections,
            text: fragments.joined(separator: " · ")
        )
    }

    private func githubRow() -> ProviderRow? {
        var fragments: [String] = ["GitHub"]
        if snapshot.githubEventsCount > 0 {
            fragments.append("\(snapshot.githubEventsCount) event\(snapshot.githubEventsCount == 1 ? "" : "s")")
        }
        if let stats = snapshot.githubPRCycleStats, stats.sampleCount > 0 {
            fragments.append("PR cycle \(durationLabel(TimeInterval(stats.medianSeconds)))")
        }
        guard fragments.count > 1 else { return nil }
        return ProviderRow(
            iconAsset: LeafIcons.nav.connections,
            text: fragments.joined(separator: " · ")
        )
    }

    private func slackRow() -> ProviderRow? {
        var fragments: [String] = ["Slack"]
        if snapshot.slackMessagesCount > 0 {
            fragments.append("\(snapshot.slackMessagesCount) msg\(snapshot.slackMessagesCount == 1 ? "" : "s")")
        }
        if snapshot.slackHuddleMinutes > 0 {
            fragments.append("\(snapshot.slackHuddleMinutes)m huddle")
        }
        if snapshot.slackReactionsReceived > 0 {
            fragments.append("\(snapshot.slackReactionsReceived) reaction\(snapshot.slackReactionsReceived == 1 ? "" : "s")")
        }
        guard fragments.count > 1 else { return nil }
        return ProviderRow(
            iconAsset: LeafIcons.nav.connections,
            text: fragments.joined(separator: " · ")
        )
    }

    private func durationLabel(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return String(format: "%.1fh", seconds / 3600) }
        return String(format: "%.1fd", seconds / 86_400)
    }
}

// MARK: - Free helpers (file-private)

private func focusTotal(_ snapshot: InsightsSnapshot) -> TimeInterval {
    snapshot.topApps.map(\.duration).reduce(0, +)
}

/// Most-recent session counts as 'active' iff its end is within
/// LeafStatusPillTokens.activeThresholdSeconds. Single source of truth
/// — same threshold as RootView's toolbar pill, so 'Hero says active' ↔
/// 'pill says active' stay in lockstep.
private func activeSession(_ snapshot: InsightsSnapshot) -> ActivitySession? {
    guard let recent = snapshot.recentSessions.first else { return nil }
    let age = Date().timeIntervalSince(recent.end)
    return age <= LeafStatusPillTokens.activeThresholdSeconds ? recent : nil
}
