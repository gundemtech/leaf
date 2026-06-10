//
//  ActivityView.swift
//  Track 2 / D3 — Activity screen on D1 substrate. Two modes via LeafTab —
//  Sessions (continuous work blocks per app/context) and Raw events (every
//  captured event, filterable per provider). 5-state UX (loading /
//  notConfigured / empty / error / loaded). Custom Chip / FilterBar
//  components dropped — both pickers use D1 LeafTab (organism O9).
//

import SwiftUI
import LeafCore

struct ActivityView: View {
    @Environment(InsightsReader.self) private var reader
    @State private var selectedFilter: ActivityFilter = .all
    @State private var mode: ActivityMode = .sessions
    @State private var feedReader = ActivityFeedReader()
    @State private var selectedEventIDs: Set<Int64> = []
    @State private var escalationSeed: EscalationSeed? = nil

    /// Кап выбора = consent-кап escalation send-пути.
    private static let selectionCap = EscalationDraft.selectionCap

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LeafSpace.xl) {
                header
                stateContent
            }
            .padding(LeafSpace.xxl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { reader.refresh() }
        .task(id: mode) {
            if mode == .rawEvents { await feedReader.refresh() }
        }
        .sheet(item: $escalationSeed, onDismiss: { selectedEventIDs.removeAll() }) { seed in
            EscalationSheet(seed: seed, onDismiss: { escalationSeed = nil })
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: LeafSpace.sm) {
            Text("ACTIVITY · TODAY")
                .leafSectionLabel()
                .foregroundStyle(LeafColor.text.tertiary)
            Text(mode == .sessions
                 ? "Continuous work blocks: app + window/file context."
                 : "Every event the agent has captured today.")
                .font(LeafType.body.regular)
                .foregroundStyle(LeafColor.text.secondary)
        }
    }

    // MARK: - State machine UX

    @ViewBuilder
    private var stateContent: some View {
        switch reader.state {
        case .loading:
            loadingView
        case .notConfigured(let msg):
            LeafEmptyState(
                icon: LeafIcons.status.warning,
                title: msg
            )
        case .empty(let msg):
            LeafEmptyState(
                icon: LeafIcons.brand.leaf,
                title: "Nothing yet today",
                description: msg
            )
        case .error(let msg):
            LeafBanner(
                tone: .danger,
                title: "Couldn't load today's events",
                description: msg,
                ctaTitle: "Try again",
                onCTA: { reader.refresh(force: true) }
            )
        case .loaded(let snapshot, _):
            loadedContent(for: snapshot)
        }
    }

    private var loadingView: some View {
        HStack(spacing: LeafSpace.sm) {
            ProgressView().controlSize(.small)
            Text("Reading today's events…")
                .font(LeafType.body.regular)
                .foregroundStyle(LeafColor.text.tertiary)
        }
    }

    // MARK: - Loaded content

    @ViewBuilder
    private func loadedContent(for snapshot: InsightsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: LeafSpace.lg) {
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
        LeafTab(
            selection: $mode,
            tabs: ActivityMode.allCases,
            label: { $0.title }
        )
    }

    // MARK: - Sessions mode

    @ViewBuilder
    private func sessionsContent(for snapshot: InsightsSnapshot) -> some View {
        let sessions = snapshot.recentSessions.sorted { $0.start > $1.start }
        LeafCard(variant: .raised, padding: .tight) {
            if sessions.isEmpty {
                inlineEmpty(
                    title: "No sessions yet",
                    description: "Switch between apps or files for a few minutes."
                )
            } else {
                listColumn(rows: sessions, leadingIndent: LeafSpace.xxxxl) { session in
                    SessionRow(session: session)
                        .padding(.horizontal, LeafSpace.md)
                        .padding(.vertical, LeafSpace.sm)
                }
            }
        }
    }

    // MARK: - Raw events mode

    @ViewBuilder
    private func rawEventsContent(for snapshot: InsightsSnapshot) -> some View {
        // AI-UI-2 — живой источник: ActivityFeedReader → ActivityFeedQuery
        // (LeafCore). Заменяет выпиленный в IV.A.2 protocol-метод.
        switch feedReader.state {
        case .loading:
            loadingView
        case .error(let msg):
            LeafBanner(
                tone: .danger,
                title: "Couldn't load today's events",
                description: msg,
                ctaTitle: "Try again",
                onCTA: { Task { await feedReader.refresh() } }
            )
        case .loaded(let entries):
            rawEventsList(entries: entries)
        }
    }

    @ViewBuilder
    private func rawEventsList(entries: [ActivityFeedEntry]) -> some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            filterPicker(counts: providerCounts(in: entries))

            if entries.isEmpty {
                LeafCard(variant: .raised, padding: .tight) {
                    inlineEmpty(
                        title: "No events yet",
                        description: "Give the agent a few minutes."
                    )
                }
            } else {
                let filtered = entries.filter { selectedFilter.matches($0.provider) }
                LeafCard(variant: .raised, padding: .tight) {
                    if filtered.isEmpty {
                        inlineEmpty(
                            title: "No \(selectedFilter.title.lowercased()) events",
                            description: "Nothing in this filter window."
                        )
                    } else {
                        listColumn(rows: filtered, leadingIndent: LeafSpace.xxxxl) { entry in
                            selectableRow(entry)
                                .padding(.horizontal, LeafSpace.md)
                                .padding(.vertical, LeafSpace.sm)
                        }
                    }
                }
                analyzeBar(entries: entries)
            }
        }
    }

    // MARK: - Selection (escalation entry point)

    private func selectableRow(_ entry: ActivityFeedEntry) -> some View {
        HStack(spacing: LeafSpace.sm) {
            Button {
                toggleSelection(entry.id)
            } label: {
                Image(systemName: selectedEventIDs.contains(entry.id)
                      ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedEventIDs.contains(entry.id)
                                     ? LeafColor.text.primary : LeafColor.text.tertiary)
            }
            .buttonStyle(.plain)
            .help("Select for AI analysis (up to \(Self.selectionCap) events per request)")
            ActivityRow(entry: entry)
        }
    }

    private func toggleSelection(_ id: Int64) {
        if selectedEventIDs.contains(id) {
            selectedEventIDs.remove(id)
        } else if selectedEventIDs.count < Self.selectionCap {
            selectedEventIDs.insert(id)
        }
    }

    @ViewBuilder
    private func analyzeBar(entries: [ActivityFeedEntry]) -> some View {
        if !selectedEventIDs.isEmpty {
            HStack {
                Button("Analyze with AI (\(selectedEventIDs.count))") {
                    escalationSeed = .ids(entries.filter { selectedEventIDs.contains($0.id) })
                }
                Button("Clear") { selectedEventIDs.removeAll() }
                    .buttonStyle(.plain)
                    .foregroundStyle(LeafColor.text.tertiary)
                Spacer()
            }
        }
    }

    private func filterPicker(counts: [ActivityProvider: Int]) -> some View {
        LeafTab(
            selection: $selectedFilter,
            tabs: ActivityFilter.allCases,
            label: { filter in
                let count: Int = {
                    switch filter {
                    case .all:    return counts.values.reduce(0, +)
                    case .local, .linear, .github, .slack, .ai:
                        guard let p = filter.provider else { return 0 }
                        return counts[p, default: 0]
                    }
                }()
                return count > 0 ? "\(filter.title) · \(count)" : filter.title
            }
        )
    }

    private func providerCounts(in entries: [ActivityFeedEntry]) -> [ActivityProvider: Int] {
        var counts: [ActivityProvider: Int] = [:]
        for entry in entries {
            counts[entry.provider, default: 0] += 1
        }
        return counts
    }

    // MARK: - List composition

    @ViewBuilder
    private func listColumn<Item: Identifiable, Row: View>(
        rows: [Item],
        leadingIndent: CGFloat,
        @ViewBuilder row: @escaping (Item) -> Row
    ) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, item in
                row(item)
                if idx < rows.count - 1 {
                    LeafDivider(style: .soft)
                        .padding(.leading, leadingIndent)
                }
            }
        }
    }

    private func inlineEmpty(title: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: LeafSpace.xxs) {
            Text(title)
                .font(LeafType.body.regular)
                .foregroundStyle(LeafColor.text.primary)
            Text(description)
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.tertiary)
        }
        .padding(.horizontal, LeafSpace.md)
        .padding(.vertical, LeafSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Mode toggle

enum ActivityMode: String, CaseIterable, Hashable, Identifiable {
    case sessions
    case rawEvents

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sessions:  "Sessions"
        case .rawEvents: "Raw events"
        }
    }
}

// MARK: - Filter enum (preserved as-is — already Identifiable)

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
