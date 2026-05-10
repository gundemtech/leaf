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

/// Hero app-icon size — 40pt. Squircle включает ~10% внутреннего padding'а,
/// визуальное «тело» ≈ 36pt, что близко к line-height `title.large` (28pt
/// font ≈ 34pt line-height). Иконка визуально лежит «по одной линии» с title.
/// Не входит в LeafIconSize tokens (.xl = 32pt) — hero единственный consumer.
private let heroIconSize: CGFloat = 40

/// Bleached leaf-green for cosmetic accent tints (provider row icons,
/// RIGHT NOW column headers). `accent.subtle` в dark mode = 35%-alpha
/// dark-green fill — для foreground tint'а нечитаем. Используем
/// primary с opacity'ом — тот же hue, мягче читается.
extension Color {
    static var leafAccentBleached: Color { LeafColor.accent.primary.opacity(0.6) }
}

/// Custom alignment guide — центрирует hero icon по центру title-line,
/// не по центру всей пары (title+caption). Без этого `.center` HStack
/// тянет иконку вниз к мидпойнту между title и caption.
extension VerticalAlignment {
    private struct HeroTitleCenter: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[VerticalAlignment.center]
        }
    }
    static let heroTitleCenter = VerticalAlignment(HeroTitleCenter.self)
}

/// Hero caption fallback truncation when no Linear ID matches the active
/// session's contextLabel — caps at this many chars before middle-truncating
/// (window titles get long fast: "leaf — D1 Design finish — caffeinate ◂…").
/// Tuned so the caption reads cleanly on the default window's hero region
/// without bleeding into next line.
private let heroContextMaxLength: Int = 40

struct HomeView: View {
    @Environment(InsightsReader.self) private var reader
    @Environment(WindowState.self) private var windowState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LeafSpace.xl) {
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

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.xl) {
            HeroBlock(snapshot: snapshot)

            if !snapshot.presenceState.isEmpty {
                LivePresenceWidget(snapshot: snapshot.presenceState)
            }

            if hasTodayContent {
                TodaySection(snapshot: snapshot)
            }

            if !snapshot.recentSessions.isEmpty || hasTodayContent || !snapshot.presenceState.isEmpty {
                RecentSessionsBlock(sessions: snapshot.recentSessions)
            }
        }
    }

    private var hasTodayContent: Bool {
        focusTotal(snapshot) > 0
            || snapshot.linearIssuesTouched > 0
            || snapshot.githubEventsCount > 0
            || snapshot.slackMessagesCount > 0
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
            HStack(alignment: .heroTitleCenter, spacing: LeafSpace.md) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: heroIconSize, height: heroIconSize)
                    .alignmentGuide(.heroTitleCenter) { $0.height / 2 }
                VStack(alignment: .leading, spacing: LeafSpace.xs) {
                    title
                        .font(LeafType.title.large)
                        .alignmentGuide(.heroTitleCenter) { $0.height / 2 }
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
