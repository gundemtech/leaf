import SwiftUI
import LeafCore

struct HomeView: View {
    @Environment(InsightsReader.self) private var reader

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                switch reader.state {
                case .loading:
                    HomePlaceholder.loading
                case .notConfigured(let msg), .empty(let msg), .error(let msg):
                    HomePlaceholder.message(msg)
                case .loaded(let snapshot, _):
                    HomeContent(snapshot: snapshot)
                }
            }
            .padding(40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { reader.refresh() }
    }
}

// MARK: - Loaded content

private struct HomeContent: View {
    let snapshot: InsightsSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HeroBlock(snapshot: snapshot)
            LivePresenceWidget(snapshot: snapshot.presenceState)
            LeafGlassGroup(spacing: 16) {
                metricGrid
            }
            PeakFocusChart(peakHour: snapshot.peakProductivityHour)
            TopAppsList(entries: Array(snapshot.topApps.prefix(5)))
            RecentSessionsBlock(sessions: snapshot.recentSessions)
            ProvidersBlock(snapshot: snapshot)
        }
    }

    private var metricGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 220), spacing: 16)],
            spacing: 16
        ) {
            MetricCard(
                title: "Focus",
                value: formatDuration(focusTotal),
                caption: snapshot.sessions.isEmpty ? nil : "\(snapshot.sessions.count) sessions",
                trend: trendFromDelta(snapshot.weekOverWeekDelta)
            )
            MetricCard(
                title: "Switching",
                value: String(format: "%.1f×", snapshot.switchRate),
                caption: "context switches per hour"
            )
            MetricCard(
                title: "AI ratio",
                value: percentage(snapshot.aiRatio),
                caption: snapshot.aiActiveSeconds > 0
                    ? "\(formatDuration(snapshot.aiActiveSeconds)) with AI"
                    : "no AI activity yet"
            )
            MetricCard(
                title: "Streak",
                value: streakValue,
                caption: streakCaption
            )
        }
    }

    /// Сумма активного времени по top-приложениям. Совпадает с цифрой
    /// из popover hero "Focus today — Xh Ym".
    private var focusTotal: TimeInterval {
        snapshot.topApps.map(\.duration).reduce(0, +)
    }

    private var streakValue: String {
        let days = snapshot.deepWorkStreak.days
        return days == 0 ? "—" : "\(days)"
    }

    private var streakCaption: String {
        let days = snapshot.deepWorkStreak.days
        guard days > 0 else { return "no deep streak yet" }
        return "\(days) day\(days == 1 ? "" : "s") deep · " + formatDuration(snapshot.deepWorkStreak.totalSeconds)
    }

    private func percentage(_ value: Double) -> String {
        String(format: "%.0f%%", max(0, min(1, value)) * 100)
    }

    private func trendFromDelta(_ delta: Double?) -> MetricCard.Trend? {
        guard let delta else { return nil }
        let pct = Int(delta.rounded())
        if pct > 1 { return .up("\(pct)% vs last week") }
        if pct < -1 { return .down("\(abs(pct))% vs last week") }
        return .flat("flat vs last week")
    }
}

// MARK: - Hero block

private struct HeroBlock: View {
    let snapshot: InsightsSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FOCUS TODAY")
                .leafLabelStyle()
            Text(formatDuration(focusTotal))
                .font(.leafTitle)
                .foregroundStyle(.leafInk)
            if let caption = sublineCaption {
                Text(caption)
                    .font(.leafBody)
                    .foregroundStyle(.leafMuted)
            }
        }
    }

    private var focusTotal: TimeInterval {
        snapshot.topApps.map(\.duration).reduce(0, +)
    }

    private var sublineCaption: String? {
        let active = snapshot.activeDaysInRow
        guard active > 0 else { return nil }
        return "\(active) day\(active == 1 ? "" : "s") active in a row"
    }
}

// MARK: - Top apps

private struct TopAppsList: View {
    let entries: [AppTimeEntry]

    var body: some View {
        GlassCard(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                Text("TOP APPS")
                    .leafLabelStyle()
                if entries.isEmpty {
                    Text("No activity yet today.")
                        .font(.leafBody)
                        .foregroundStyle(.leafMuted)
                } else {
                    VStack(spacing: 10) {
                        ForEach(entries, id: \.bundleID) { entry in
                            HStack {
                                Text(AppNameResolver.shared.displayName(for: entry.bundleID))
                                    .font(.leafBody)
                                    .foregroundStyle(.leafInk)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(formatDuration(entry.duration))
                                    .font(.leafBody.monospacedDigit())
                                    .foregroundStyle(.leafMuted)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Placeholders

private enum HomePlaceholder {
    static var loading: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("FOCUS TODAY").leafLabelStyle()
            ProgressView()
        }
    }

    static func message(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("FOCUS TODAY").leafLabelStyle()
            Text(text)
                .font(.leafBody)
                .foregroundStyle(.leafMuted)
        }
    }
}
