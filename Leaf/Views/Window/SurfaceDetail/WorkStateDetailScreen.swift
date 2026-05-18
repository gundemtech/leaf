//
//  WorkStateDetailScreen.swift
//  Track 7 P3 — detail screen for the always-on D3 Work State surface.
//  Bypasses SurfaceDetailLayout (whose chartBlock fixed-height LeafCard wrap
//  is the wrong shape for a sub-tab strip + per-tab varying content); composes
//  directly from LeafTab + LeafCard + LeafSection primitives.
//
//  Visual rhythm mirrors the SurfaceDetailLayout 4-section convention but
//  has 5 sections: range-tab → headline → sub-tab → aggregates → list.
//

import LeafCore
import SwiftUI

struct WorkStateDetailScreen: View {
    @State private var vm: WorkStateDetailViewModel

    init(vm: WorkStateDetailViewModel = WorkStateDetailViewModel()) {
        _vm = State(initialValue: vm)
    }

    var body: some View {
        Group {
            switch vm.state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .error(let message):
                errorBanner(message)
            case .loaded(let payload):
                loadedContent(payload: payload)
            }
        }
        .navigationTitle("Work State")
        .onAppear { vm.reload() }
    }

    // MARK: - Error

    private func errorBanner(_ message: String) -> some View {
        VStack {
            LeafBanner(tone: .danger, title: message)
            Spacer()
        }
        .padding(LeafSpace.xxl)
    }

    // MARK: - Loaded

    @ViewBuilder
    private func loadedContent(payload: WorkStateDetailPayload) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LeafSpace.xl) {
                rangeTabStrip
                headlineBlock(payload: payload)
                subTabStrip
                aggregatesBlock(payload: payload)
                listBlock(payload: payload)
            }
            .padding(LeafSpace.xxl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Range tab

    private var rangeTabStrip: some View {
        LeafTab(
            selection: Binding(get: { vm.range }, set: { vm.range = $0 }),
            tabs: DetailRange.allCases,
            label: { tab in
                switch tab {
                case .today: "Today"
                case .week: "Week"
                case .month: "Month"
                }
            }
        )
    }

    // MARK: - Headline

    @ViewBuilder
    private func headlineBlock(payload: WorkStateDetailPayload) -> some View {
        Text(headlineText(payload: payload))
            .font(LeafType.title.large)
            .foregroundStyle(LeafColor.text.primary)
    }

    private func headlineText(payload: WorkStateDetailPayload) -> String {
        let q = payload.openQuestionsCount
        let b = payload.openBlockersCount
        let d = payload.decisionsCount
        var parts: [String] = []
        if q > 0 { parts.append("\(q) open question\(q == 1 ? "" : "s")") }
        if b > 0 { parts.append("\(b) blocker\(b == 1 ? "" : "s")") }
        if d > 0 { parts.append("\(d) decision\(d == 1 ? "" : "s")") }
        guard !parts.isEmpty else {
            return "Nothing to show — D3 detectors have not produced anything for this period"
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Sub-tab

    private var subTabStrip: some View {
        LeafTab(
            selection: Binding(get: { vm.subTab }, set: { vm.subTab = $0 }),
            tabs: WorkStateSubTab.allCases,
            label: { $0.displayName }
        )
    }

    // MARK: - Aggregates per active sub-tab

    @ViewBuilder
    private func aggregatesBlock(payload: WorkStateDetailPayload) -> some View {
        LeafSection(title: "Summary") {
            LeafCard(padding: .regular) {
                Text(aggregatesText(payload: payload))
                    .font(LeafType.body.regular)
                    .foregroundStyle(LeafColor.text.primary)
            }
        }
    }

    private func aggregatesText(payload: WorkStateDetailPayload) -> String {
        switch vm.subTab {
        case .decisions:
            let n = payload.decisions.count
            guard n > 0 else { return "No decisions in this period" }
            let avg = payload.decisions.map(\.confidence).reduce(0, +) / Double(n)
            let pct = Int((avg * 100).rounded())
            return "Count: \(n) · Avg confidence: \(pct)%"
        case .questions:
            let o = payload.openQuestionsCount
            let r = payload.resolvedQuestionsCount
            let opens = payload.questions.filter { $0.resolvedAtMs == nil }
            let avgAgeMs: Int64? =
                opens.isEmpty
                ? nil
                : opens.map { Int64(Date().timeIntervalSince1970 * 1000) - $0.openedAtMs }.reduce(0, +)
                    / Int64(opens.count)
            var fragments: [String] = ["Open: \(o)", "Resolved: \(r)"]
            if let age = avgAgeMs {
                fragments.append("Avg open age: \(formatAge(ms: age))")
            }
            return fragments.joined(separator: " · ")
        case .blockers:
            let o = payload.openBlockersCount
            let r = payload.resolvedBlockersCount
            let byKind = Dictionary(
                grouping: payload.blockers.filter { $0.resolvedAtMs == nil },
                by: { $0.targetKind.displayName }
            )
            .map { "\($0.value.count)x \($0.key)" }
            .sorted()
            .joined(separator: ", ")
            var fragments: [String] = ["Open: \(o)", "Resolved: \(r)"]
            if !byKind.isEmpty {
                fragments.append("By target: \(byKind)")
            }
            return fragments.joined(separator: " · ")
        case .whereStopped:
            let n = payload.whereStoppedCount
            guard let latest = payload.whereStopped.first else {
                return "No snapshots yet"
            }
            let ageMs = Int64(Date().timeIntervalSince1970 * 1000) - latest.generatedAtMs
            return "Snapshots: \(n) · Last: \(formatAge(ms: ageMs)) ago"
        }
    }

    // MARK: - List per active sub-tab

    @ViewBuilder
    private func listBlock(payload: WorkStateDetailPayload) -> some View {
        switch vm.subTab {
        case .decisions:
            if payload.decisions.isEmpty {
                emptyState(for: .decisions)
            } else {
                LeafSection(title: "Recent") {
                    VStack(spacing: LeafSpace.sm) {
                        ForEach(payload.decisions.prefix(30), id: \.id) { d in
                            decisionRow(d)
                        }
                    }
                }
            }
        case .questions:
            if payload.questions.isEmpty {
                emptyState(for: .questions)
            } else {
                LeafSection(title: "Recent") {
                    VStack(spacing: LeafSpace.sm) {
                        let open = payload.questions.filter { $0.resolvedAtMs == nil }
                            .sorted { $0.openedAtMs > $1.openedAtMs }
                        let resolved = payload.questions.filter { $0.resolvedAtMs != nil }
                            .sorted { ($0.resolvedAtMs ?? 0) > ($1.resolvedAtMs ?? 0) }
                        let combined = Array((open + resolved).prefix(30))
                        ForEach(combined, id: \.id) { q in
                            questionRow(q)
                        }
                    }
                }
            }
        case .blockers:
            if payload.blockers.isEmpty {
                emptyState(for: .blockers)
            } else {
                LeafSection(title: "Recent") {
                    VStack(spacing: LeafSpace.sm) {
                        let open = payload.blockers.filter { $0.resolvedAtMs == nil }
                            .sorted { $0.startedAtMs > $1.startedAtMs }
                        let resolved = payload.blockers.filter { $0.resolvedAtMs != nil }
                            .sorted { ($0.resolvedAtMs ?? 0) > ($1.resolvedAtMs ?? 0) }
                        let combined = Array((open + resolved).prefix(30))
                        ForEach(combined, id: \.id) { b in
                            blockerRow(b)
                        }
                    }
                }
            }
        case .whereStopped:
            if payload.whereStopped.isEmpty {
                emptyState(for: .whereStopped)
            } else {
                LeafSection(title: "Recent") {
                    VStack(spacing: LeafSpace.sm) {
                        ForEach(payload.whereStopped.prefix(20), id: \.id) { s in
                            whereStoppedRow(s)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Row builders

    private func decisionRow(_ d: Decision) -> some View {
        LeafCard(padding: .regular) {
            VStack(alignment: .leading, spacing: LeafSpace.xs) {
                Text(d.excerpt)
                    .font(LeafType.body.regular)
                    .foregroundStyle(LeafColor.text.primary)
                if !d.topicKeywords.isEmpty {
                    Text(d.topicKeywords.joined(separator: ", "))
                        .font(LeafType.body.small)
                        .foregroundStyle(LeafColor.text.secondary)
                }
                Text("\(formatRelativeAgo(d.detectedAtMs)) ago")
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.tertiary)
            }
        }
    }

    private func questionRow(_ q: OpenQuestion) -> some View {
        LeafCard(padding: .regular) {
            VStack(alignment: .leading, spacing: LeafSpace.xs) {
                Text(q.excerpt)
                    .font(LeafType.body.regular)
                    .foregroundStyle(LeafColor.text.primary)
                let captionFragments: [String] = {
                    var fr: [String] = []
                    if !q.alternatives.isEmpty {
                        fr.append("\(q.alternatives.count) alternatives")
                    }
                    if let ref = q.contextRef {
                        fr.append("→ \(refDisplayShort(ref))")
                    }
                    let ts = q.resolvedAtMs ?? q.openedAtMs
                    fr.append("\(formatRelativeAgo(ts)) ago")
                    return fr
                }()
                Text(captionFragments.joined(separator: " · "))
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.tertiary)
                    .help(q.contextRef.map(refDisplayFull) ?? "")
            }
        }
    }

    private func blockerRow(_ b: Blocker) -> some View {
        LeafCard(padding: .regular) {
            VStack(alignment: .leading, spacing: LeafSpace.xs) {
                Text(b.excerpt)
                    .font(LeafType.body.regular)
                    .foregroundStyle(LeafColor.text.primary)
                let captionFragments: [String] = [
                    "\(b.targetKind.displayName): \(b.targetRef)",
                    "\(formatRelativeAgo(b.resolvedAtMs ?? b.startedAtMs)) ago",
                ]
                Text(captionFragments.joined(separator: " · "))
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.tertiary)
            }
        }
    }

    private func whereStoppedRow(_ s: WhereStoppedSnapshot) -> some View {
        LeafCard(padding: .regular) {
            VStack(alignment: .leading, spacing: LeafSpace.xs) {
                Text(s.excerpt)
                    .font(LeafType.body.regular)
                    .foregroundStyle(LeafColor.text.primary)
                if !s.wipSignals.isEmpty {
                    Text(s.wipSignals.joined(separator: " · "))
                        .font(LeafType.body.small)
                        .foregroundStyle(LeafColor.text.secondary)
                }
                Text("\(formatRelativeAgo(s.generatedAtMs)) ago")
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.tertiary)
            }
        }
    }

    // MARK: - Empty per sub-tab

    @ViewBuilder
    private func emptyState(for tab: WorkStateSubTab) -> some View {
        VStack {
            Spacer()
            LeafEmptyState(
                icon: LeafIcons.brand.leaf,
                title: emptyTitle(for: tab),
                description: emptyDescription(for: tab)
            )
            Spacer()
        }
        .frame(minHeight: LeafEmptyStateTokens.centeredMinHeight)
    }

    private func emptyTitle(for tab: WorkStateSubTab) -> String {
        switch tab {
        case .decisions: return "No decisions logged yet"
        case .questions: return "No open questions"
        case .blockers: return "No blockers"
        case .whereStopped: return "No work-state snapshots yet"
        }
    }

    private func emptyDescription(for tab: WorkStateSubTab) -> String {
        switch tab {
        case .decisions:
            return "Decisions surface here when Leaf detects them in your activity stream."
        case .questions:
            return
                "Questions you've raised in chat or comments surface here when Leaf detects them. None active right now."
        case .blockers:
            return "Blocking states (waiting for review, stuck Linear issues) surface here. Nothing blocked right now."
        case .whereStopped:
            return "Leaf periodically captures a 'where you left off' snapshot. None recorded yet for this range."
        }
    }

    // MARK: - Helpers

    private func refDisplayShort(_ ref: ContextRef) -> String {
        switch ref {
        case .slackThread: return "Slack thread"
        case .linearIssue(let r): return r
        case .githubPR(let r): return r
        }
    }

    private func refDisplayFull(_ ref: ContextRef) -> String {
        switch ref {
        case .slackThread(let ts): return "Slack thread @ \(ts)"
        case .linearIssue(let r): return "Linear issue \(r)"
        case .githubPR(let r): return "GitHub PR \(r)"
        }
    }

    private func formatRelativeAgo(_ ms: Int64) -> String {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let ageMs = max(0, now - ms)
        return formatAge(ms: ageMs)
    }

    private func formatAge(ms: Int64) -> String {
        let s = ms / 1000
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }
}
