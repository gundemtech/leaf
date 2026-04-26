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
    @State private var reader = InsightsReader()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !launchAgent.isEnabled {
                agentOffBanner
            }
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
            reader.refresh()
        }
    }

    // MARK: - Sections

    private var agentOffBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Background collection is off")
                .font(.caption)
            Spacer()
            Button("Enable") { openSettingsWindow() }
                .buttonStyle(.link)
                .font(.caption)
        }
    }

    // TODO Phase 3 onboarding: surface AX/FDA permission denials.
    // Когда AX denied → AppNameResolver работает, но AXWebArea browser-URL
    // collection (v1.1) не будет; когда FDA denied → FSEvents под
    // ~/Documents и ~/Desktop недоступны (callback тихо не приходит).
    // UX: orange banner ниже agentOffBanner с "Grant Accessibility →"
    // / "Grant Full Disk Access →" кнопками открывающими System Settings
    // deep links (x-apple.systempreferences:com.apple.preference.security).
    private var permissionsBanner: some View { EmptyView() }

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
