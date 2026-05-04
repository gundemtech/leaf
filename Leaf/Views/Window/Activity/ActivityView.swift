import SwiftUI
import LeafCore

struct ActivityView: View {
    @Environment(InsightsReader.self) private var reader
    @State private var selectedFilter: ActivityFilter = .all
    @State private var mode: ActivityMode = .sessions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                switch reader.state {
                case .loading:
                    loadingPlaceholder
                case .notConfigured(let msg), .empty(let msg), .error(let msg):
                    placeholder(msg)
                case .loaded(let snapshot, _):
                    content(for: snapshot)
                }
            }
            .padding(40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { reader.refresh() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ACTIVITY · TODAY")
                .leafLabelStyle()
            Text(mode == .sessions
                 ? "Continuous work blocks: app + window/file context."
                 : "Every event the agent has captured today.")
                .font(.leafBody)
                .foregroundStyle(.leafMuted)
        }
    }

    // MARK: - Loaded content

    @ViewBuilder
    private func content(for snapshot: InsightsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            modePicker
            switch mode {
            case .sessions:
                sessionsContent(for: snapshot)
            case .rawEvents:
                rawEventsContent(for: snapshot)
            }
        }
    }

    private var modePicker: some View {
        Picker("", selection: $mode) {
            ForEach(ActivityMode.allCases, id: \.self) { m in
                Text(m.title).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 240)
    }

    // MARK: - Sessions mode

    @ViewBuilder
    private func sessionsContent(for snapshot: InsightsSnapshot) -> some View {
        let sessions = snapshot.recentSessions.sorted { $0.start > $1.start }
        if sessions.isEmpty {
            placeholder("No sessions yet — switch between apps or files for a few minutes.")
        } else {
            GlassCard(padding: 8) {
                VStack(spacing: 0) {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                        SessionRow(session: session)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                        if index < sessions.count - 1 {
                            Divider().opacity(0.3).padding(.leading, 56)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Raw events mode

    @ViewBuilder
    private func rawEventsContent(for snapshot: InsightsSnapshot) -> some View {
        let entries = snapshot.recentActivity
        FilterBar(selected: $selectedFilter, counts: providerCounts(in: entries))

        if entries.isEmpty {
            placeholder("No events captured today yet — give the agent a few minutes.")
        } else {
            let filtered = entries.filter { selectedFilter.matches($0.provider) }
            if filtered.isEmpty {
                placeholder("No \(selectedFilter.title.lowercased()) events in this window.")
            } else {
                GlassCard(padding: 8) {
                    VStack(spacing: 0) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, entry in
                            ActivityRow(entry: entry)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                            if index < filtered.count - 1 {
                                Divider().opacity(0.3).padding(.leading, 44)
                            }
                        }
                    }
                }
            }
        }
    }

    private func providerCounts(in entries: [ActivityFeedEntry]) -> [ActivityProvider: Int] {
        var counts: [ActivityProvider: Int] = [:]
        for entry in entries {
            counts[entry.provider, default: 0] += 1
        }
        return counts
    }

    // MARK: - Placeholders

    private var loadingPlaceholder: some View {
        HStack {
            ProgressView()
                .controlSize(.small)
            Text("Reading today's events…")
                .font(.leafBody)
                .foregroundStyle(.leafMuted)
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.leafBody)
            .foregroundStyle(.leafMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Mode toggle

enum ActivityMode: String, CaseIterable, Hashable {
    case sessions
    case rawEvents

    var title: String {
        switch self {
        case .sessions:  "Sessions"
        case .rawEvents: "Raw events"
        }
    }
}

// MARK: - Filter bar

private struct FilterBar: View {
    @Binding var selected: ActivityFilter
    let counts: [ActivityProvider: Int]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ActivityFilter.allCases) { filter in
                Chip(
                    title: filter.title,
                    count: countText(for: filter),
                    isSelected: filter == selected
                ) {
                    selected = filter
                }
            }
            Spacer()
        }
    }

    private func countText(for filter: ActivityFilter) -> String? {
        switch filter {
        case .all:
            let total = counts.values.reduce(0, +)
            return total == 0 ? nil : "\(total)"
        case .local, .linear, .github, .slack, .ai:
            let n = counts[filter.provider!, default: 0]
            return n == 0 ? nil : "\(n)"
        }
    }
}

private struct Chip: View {
    let title: String
    let count: String?
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.leafBody)
                if let count {
                    Text(count)
                        .font(.leafCaption.monospacedDigit())
                        .foregroundStyle(isSelected ? Color.white.opacity(0.8) : .leafMuted)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? Color.leafAccentDeep : Color.leafCard.opacity(0.7))
            )
            .foregroundStyle(isSelected ? Color.white : Color.leafInk)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? Color.clear : Color.leafInk.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Filter enum

enum ActivityFilter: String, CaseIterable, Identifiable {
    case all, local, linear, github, slack, ai

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:    "All"
        case .local:  "Local"
        case .linear: "Linear"
        case .github: "GitHub"
        case .slack:  "Slack"
        case .ai:     "AI"
        }
    }

    var provider: ActivityProvider? {
        switch self {
        case .all:    nil
        case .local:  .local
        case .linear: .linear
        case .github: .github
        case .slack:  .slack
        case .ai:     .ai
        }
    }

    func matches(_ provider: ActivityProvider) -> Bool {
        guard let p = self.provider else { return true }
        return p == provider
    }
}
