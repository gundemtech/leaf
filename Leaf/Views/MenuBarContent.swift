//
//  MenuBarContent.swift
//  Leaf
//
//  Popover в menu bar: Today header, top-5 apps с durations, bar chart.
//  Требует .menuBarExtraStyle(.window) — Charts не рендерится в .menu стиле.
//

import SwiftUI
import AppKit
import Charts
import LeafCore

struct MenuBarContent: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(LaunchAgentService.self) private var launchAgent
    @Environment(PermissionsService.self) private var permissions
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var reader = InsightsReader()

    var body: some View {
        if hasCompletedOnboarding {
            normalBody
        } else {
            OnboardingView(onDone: {
                hasCompletedOnboarding = true
                // Cleanup: если юзер reset'нет hasCompletedOnboarding в debug,
                // onboarding starts с .welcome заново вместо middle-of-flow.
                UserDefaults.standard.removeObject(forKey: "onboardingStep")
            })
        }
    }

    private var normalBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !launchAgent.isEnabled {
                agentOffBanner
            }
            permissionsBanner
            header
            Divider()
            content
            Divider()
            controls
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            launchAgent.refreshStatus()
            permissions.refresh()
            permissions.startPolling(every: 4.0)
            reader.refresh()
        }
        .onDisappear {
            permissions.stopPolling()
        }
    }

    // MARK: - Sections

    private var agentOffBanner: some View {
        BannerView(
            color: .orange,
            title: "Background collection is off",
            action: "Enable",
            onTap: openSettingsWindow
        )
    }

    /// Phase 3.4 — surface AX/FDA denials. AX-deny приоритет: без AX
    /// AppNameResolver работает, но window-title / browser-URL (v1.1) — нет.
    /// FDA-deny — secondary: FSEvents под ~/Documents / ~/Desktop недоступны
    /// (callback тихо не приходит, watched_folders просто не дают данных).
    @ViewBuilder
    private var permissionsBanner: some View {
        if !permissions.axGranted {
            BannerView(
                color: .orange,
                title: "Accessibility disabled",
                action: "Grant",
                onTap: permissions.openAXSettings
            )
        } else if !permissions.fdaGranted {
            BannerView(
                color: .orange,
                title: "Full Disk Access disabled",
                subtitle: "Watched Folders won't track ~/Documents",
                action: "Grant",
                onTap: permissions.openFDASettings
            )
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Today")
                .font(.headline)
            Spacer()
            if case .loaded(_, let ts) = reader.state {
                Text(ts, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch reader.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 60)
        case .notConfigured(let msg), .empty(let msg), .error(let msg):
            Text(msg)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        case .loaded(let snapshot, _):
            loadedContent(snapshot: snapshot)
        }
    }

    private func loadedContent(snapshot: InsightsSnapshot) -> some View {
        let top = Array(snapshot.topApps.prefix(5))
        return VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(top, id: \.bundleID) { entry in
                    HStack {
                        Text(AppNameResolver.shared.displayName(for: entry.bundleID))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(formatDuration(entry.duration))
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
            }
            analyticsBlock(snapshot: snapshot)
            Chart(top, id: \.bundleID) { entry in
                BarMark(
                    x: .value("App", AppNameResolver.shared.displayName(for: entry.bundleID)),
                    y: .value("Minutes", entry.duration / 60.0)
                )
            }
            .frame(height: 120)
            .chartYAxis { AxisMarks(position: .leading) }
        }
    }

    /// Phase 2.1: sessions + switches. Phase 2.2: добавили 2 строки trends
    /// (deep streak + peak/WoW/active days). Phase 2.3: AI ratio row.
    /// Все строки graceful к empty-state — "—" / "no activity yet" placeholder
    /// показываем где insight не посчитался ещё (insufficient data).
    @ViewBuilder
    private func analyticsBlock(snapshot: InsightsSnapshot) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                sessionsLines(snapshot: snapshot)
                trendsLines(snapshot: snapshot)
                aiLine(snapshot: snapshot)
                linearLine(snapshot: snapshot)
                githubLine(snapshot: snapshot)
                slackLine(snapshot: snapshot)
                filesLines(snapshot: snapshot)
            }
            Spacer()
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func sessionsLines(snapshot: InsightsSnapshot) -> some View {
        if snapshot.sessions.isEmpty {
            Text("No focus sessions yet — keep working")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("Sessions: \(snapshot.sessions.count) · avg \(formatDuration(snapshot.avgSessionDuration)) · deep \(snapshot.deepSessionsCount)")
                .font(.caption)
            Text(String(format: "Switches: %.1f/h", snapshot.switchRate))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func trendsLines(snapshot: InsightsSnapshot) -> some View {
        if hasNoTrends(snapshot) {
            // Phase 2.5 — collapse 2 строк с множественными "—" в одну
            // строку placeholder'а пока копится первая неделя данных.
            Text("Trends appear after ~14 days of data")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            Text(streakLine(snapshot: snapshot))
                .font(.caption)
            Text(trendsSummaryLine(snapshot: snapshot))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// `activeDaysInRow <= 1` — порог "имеет смысл показать": 0 — нет
    /// активности, 1 — сегодня впервые открыли. ≥2 дней или любой другой
    /// trend ненулевой → показываем full strip (даже если часть в "—" —
    /// это уже информативно "появилось одно, копится остальное").
    private func hasNoTrends(_ snapshot: InsightsSnapshot) -> Bool {
        snapshot.deepWorkStreak.days == 0
            && snapshot.peakProductivityHour == nil
            && snapshot.weekOverWeekDelta == nil
            && snapshot.activeDaysInRow <= 1
    }

    private func streakLine(snapshot: InsightsSnapshot) -> String {
        let streak = snapshot.deepWorkStreak
        if streak.days == 0 {
            return "🔥 — · start a deep session to begin a streak"
        } else {
            let dayWord = streak.days == 1 ? "day" : "days"
            return "🔥 \(streak.days) \(dayWord) deep · \(formatDuration(streak.totalSeconds)) total"
        }
    }

    private func trendsSummaryLine(snapshot: InsightsSnapshot) -> String {
        let peak = formatPeakHour(snapshot.peakProductivityHour)
        let wow = formatWoW(snapshot.weekOverWeekDelta)
        let dayWord = snapshot.activeDaysInRow == 1 ? "day" : "days"
        return "Peak \(peak) · WoW \(wow) · Active \(snapshot.activeDaysInRow) \(dayWord)"
    }

    private func formatPeakHour(_ hour: Int?) -> String {
        guard let h = hour else { return "—" }
        return String(format: "%02d:00", h)
    }

    private func formatWoW(_ delta: Double?) -> String {
        guard let d = delta else { return "—" }
        let pct = Int((d * 100).rounded())
        if pct >= 0 {
            return "+\(pct)%"
        } else {
            return "\(pct)%"
        }
    }

    /// Phase 2.3 — AI collaboration row. Phase 2.5 — 3-state display:
    /// (1) zero — нет AI events; (2) short — < 3 мин активности, ratio %
    /// после rounding всё равно даёт "0%" (confusing) → показываем raw
    /// time без процента; (3) measured — full ratio + tooltip.
    @ViewBuilder
    private func aiLine(snapshot: InsightsSnapshot) -> some View {
        if snapshot.aiActiveSeconds == 0 {
            Text("AI: no activity yet")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else if snapshot.aiActiveSeconds < 180 {
            Text("AI today: Claude Code \(formatDurationShort(snapshot.aiActiveSeconds))")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("AI ratio today: \(formatPercentage(snapshot.aiRatio)) · Claude Code \(formatDurationShort(snapshot.aiActiveSeconds))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(aiTooltip(snapshot: snapshot))
        }
    }

    private func formatPercentage(_ ratio: Double) -> String {
        "\(Int((ratio * 100).rounded()))%"
    }

    /// "5m" / "1h 23m" — компактный, не тянет string formatter overhead.
    private func formatDurationShort(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 {
            return "\(h)h \(m)m"
        } else {
            return "\(m)m"
        }
    }

    /// Phase 4.2 — Linear issue activity. Linear opt-in feature: при отсутствии
    /// данных строка скрыта (EmptyView), а не "Linear: no activity" placeholder
    /// — иначе wreck'аем popover у юзеров без подключённого Linear (большинство).
    /// Tooltip показывает full breakdown by project + status.
    @ViewBuilder
    private func linearLine(snapshot: InsightsSnapshot) -> some View {
        if snapshot.linearIssuesTouched == 0 {
            EmptyView()
        } else {
            let topProject = snapshot.linearByProject.first?.project ?? ""
            let label: String = {
                if topProject.isEmpty || topProject == "(no project)" {
                    return "Linear today: \(snapshot.linearIssuesTouched) issues"
                } else {
                    return "Linear today: \(snapshot.linearIssuesTouched) issues · \(topProject)"
                }
            }()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(linearTooltip(snapshot: snapshot))
        }
    }

    private func linearTooltip(snapshot: InsightsSnapshot) -> String {
        var lines: [String] = ["Distinct issues touched today: \(snapshot.linearIssuesTouched)"]
        if !snapshot.linearByProject.isEmpty {
            let projects = snapshot.linearByProject
                .map { "\($0.project): \($0.count)" }
                .joined(separator: ", ")
            lines.append("By project: \(projects)")
        }
        if !snapshot.linearByStatus.isEmpty {
            let statuses = snapshot.linearByStatus
                .map { "\($0.status): \($0.count)" }
                .joined(separator: ", ")
            lines.append("By status: \(statuses)")
        }
        return lines.joined(separator: "\n")
    }

    /// Phase 4.3 — GitHub events line. На пустом GitHub (Stub в no-prod build,
    /// либо коллектора нет / юзер не подключал) — EmptyView, не показываем
    /// "GitHub: no activity" placeholder. Tooltip — full breakdown by repo + kind.
    @ViewBuilder
    private func githubLine(snapshot: InsightsSnapshot) -> some View {
        if snapshot.githubEventsCount == 0 {
            EmptyView()
        } else {
            let topRepo = snapshot.githubByRepo.first?.repo ?? ""
            let label: String = {
                if topRepo.isEmpty || topRepo == "(unknown)" {
                    return "GitHub today: \(snapshot.githubEventsCount) events"
                } else {
                    return "GitHub today: \(snapshot.githubEventsCount) events · \(topRepo)"
                }
            }()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(githubTooltip(snapshot: snapshot))
        }
    }

    private func githubTooltip(snapshot: InsightsSnapshot) -> String {
        var lines: [String] = ["Events today: \(snapshot.githubEventsCount)"]
        if !snapshot.githubByRepo.isEmpty {
            let repos = snapshot.githubByRepo
                .map { "\($0.repo): \($0.count)" }
                .joined(separator: ", ")
            lines.append("By repo: \(repos)")
        }
        if !snapshot.githubByEventKind.isEmpty {
            let kinds = snapshot.githubByEventKind
                .map { "\($0.eventKind): \($0.count)" }
                .joined(separator: ", ")
            lines.append("By kind: \(kinds)")
        }
        return lines.joined(separator: "\n")
    }

    /// Phase 4.4 — Slack activity line. Если ни сообщений, ни huddle минут нет
    /// (Stub в no-prod build, провайдер ещё не подключён, юзер не подключал) —
    /// EmptyView. Tooltip — full breakdown по channel + huddle minutes.
    @ViewBuilder
    private func slackLine(snapshot: InsightsSnapshot) -> some View {
        if snapshot.slackMessagesCount == 0 && snapshot.slackHuddleMinutes == 0 {
            EmptyView()
        } else {
            let parts: [String?] = [
                "\(snapshot.slackMessagesCount) msgs",
                snapshot.slackByChannel.isEmpty ? nil : "\(snapshot.slackByChannel.count) channels",
                snapshot.slackHuddleMinutes > 0 ? "huddle \(formatHuddleMinutes(snapshot.slackHuddleMinutes))" : nil
            ]
            let label = "Slack today: " + parts.compactMap { $0 }.joined(separator: " · ")
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(slackTooltip(snapshot: snapshot))
        }
    }

    private func slackTooltip(snapshot: InsightsSnapshot) -> String {
        var lines: [String] = ["Messages today: \(snapshot.slackMessagesCount)"]
        if snapshot.slackHuddleMinutes > 0 {
            lines.append("Huddle: \(formatHuddleMinutes(snapshot.slackHuddleMinutes))")
        }
        if !snapshot.slackByChannel.isEmpty {
            let channels = snapshot.slackByChannel
                .map { "\($0.channelName): \($0.count)" }
                .joined(separator: ", ")
            lines.append("By channel: \(channels)")
        }
        return lines.joined(separator: "\n")
    }

    private func formatHuddleMinutes(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    /// Phase 2.4 — top-5 files touched today из watched folders. Empty placeholder
    /// если нет content events (FSEventsCollector idle / no folders / events
    /// все coalesced). Tooltip показывает full path для L4 (UI basename).
    @ViewBuilder
    private func filesLines(snapshot: InsightsSnapshot) -> some View {
        if snapshot.filesTouched.isEmpty {
            Text("Files: no activity yet")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            Text("Files touched (top 5):")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(snapshot.filesTouched.prefix(5), id: \.self) { path in
                Text(FilenameResolver.shared.displayName(for: path))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
            }
        }
    }

    private func aiTooltip(snapshot: InsightsSnapshot) -> String {
        let total = max(snapshot.aiActiveSeconds, 0)  // semantic: aiActive not > totalActive
        // Reconstruct totalActive — попадает в snapshot, но мы его не tracking;
        // показываем компонентами от ratio: total = ai / ratio.
        let totalActive: TimeInterval = snapshot.aiRatio > 0
            ? snapshot.aiActiveSeconds / snapshot.aiRatio
            : 0
        return "AI \(formatDurationShort(total)) of \(formatDurationShort(totalActive)) (\(formatPercentage(snapshot.aiRatio)))"
    }

    private var controls: some View {
        HStack {
            Button("Settings…") { openSettingsWindow() }
                .keyboardShortcut(",")
            Button("Refresh") { reader.refresh() }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    // MARK: - Helpers

    /// LSUIElement apps не активируются автоматом при openSettings() —
    /// окно появляется "за" другими. Сначала активируем app, затем открываем.
    private func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
        for window in NSApp.windows where window.title.lowercased().contains("settings")
            || window.title.lowercased().contains("leaf") {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
