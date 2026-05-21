//
//  WhereStoppedBlock.swift
//  Track 8 / Phase 8.7 — WHERE STOPPED block wired to Phase 8.1 substrate
//  (`DerivedInsights.recentWhereStopped(limit:)`). Tap → Track-7 P3
//  `WorkStateDetailScreen` via `RouteCoordinator.pushHomeWorkState()`.
//

import LeafCore
import SwiftUI

struct WhereStoppedBlock: View {
    let snapshot: WhereStoppedSnapshot?

    @Environment(RouteCoordinator.self) private var coordinator

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text(headerText)
                .leafSectionLabel()
                .foregroundStyle(LeafColor.text.tertiary)

            Button(action: { coordinator.pushHomeWorkState() }) {
                LeafCard(padding: .regular) {
                    cardContent
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Open work state details")
            .accessibilityHint(accessibilityHint)
            .animation(.easeInOut(duration: 0.25), value: snapshot)
        }
    }

    @ViewBuilder
    private var cardContent: some View {
        if hasUsableSnapshot, let snap = snapshot {
            populatedBody(snap)
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        LeafEmptyState(
            icon: LeafIcons.brand.leaf,
            title: "Last work context",
            description: "No recent stop-points captured."
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func populatedBody(_ snap: WhereStoppedSnapshot) -> some View {
        let cleanWipSignals = snap.wipSignals
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return VStack(alignment: .leading, spacing: LeafSpace.xs) {
            // Line 2 — anchor file:line (Xcode), filename only (path-only
            // fallback for VSCode/JetBrains anchors), or excerpt (commit /
            // ticket / no-anchor cases).
            Text(lineLabel(for: snap))
                .font(LeafType.title.small)
                .foregroundStyle(LeafColor.text.primary)
                .lineLimit(2)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)

            // Line 3 — last commit subject (4h cutoff applied Reader-side).
            if let commit = snap.recentLastCommit {
                Text(commitSubjectLine(commit))
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            // Line 4 — WIP signals as LeafPill chips (3-tone mapping).
            if !cleanWipSignals.isEmpty {
                HStack(spacing: LeafSpace.xs) {
                    ForEach(cleanWipSignals, id: \.self) { signal in
                        LeafPill(title: signal, tone: wipSignalTone(signal))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Track-9 T7 — Line 2 renderer. Xcode anchor → "name:line"; path-only
    /// anchor → "name"; no anchor → excerpt fallback.
    ///
    /// `snap.anchorFilePath` is guaranteed basename-only by the substrate
    /// contract (`ProdInsights+RecentWhereStopped` extracts via
    /// `(p as NSString).lastPathComponent` before populating the field).
    /// No second derivation needed here — render directly.
    private func lineLabel(for snap: WhereStoppedSnapshot) -> String {
        if let basename = snap.anchorFilePath, !basename.isEmpty {
            if let line = snap.anchorLine, line > 0 {
                return "\(basename):\(line)"
            }
            return basename
        }
        return snap.excerpt
    }

    /// Track-9 T7 — Line 3 renderer. Trim + 60-char cap + ellipsis,
    /// wrapped in quotes per spec §4.3 / master spec §9.1 C-20.
    private func commitSubjectLine(_ commit: RecentCommitSnapshot) -> String {
        let trimmed = commit.subject.trimmingCharacters(in: .whitespaces)
        let capped = trimmed.count > 60 ? String(trimmed.prefix(60)) + "…" : trimmed
        return "Last commit: \"\(capped)\""
    }

    /// Track-9 T7 — WIP pill tone mapping. Per-signal semantic intent;
    /// unknown signals fall back to neutral (safe default for future deriver
    /// extensions like `ciFailing`, currently always false per Track-1 D3).
    private func wipSignalTone(_ signal: String) -> LeafPillTokens.Tone {
        switch signal {
        case "commitWip": return .warning
        case "midEdit":   return .accent
        default:          return .neutral
        }
    }

    /// Treats a snapshot with empty `excerpt` as no-data — header drops age
    /// suffix and card falls back to `emptyState`. Substrate today never
    /// emits empty excerpts, but this defends against future producer regressions.
    private var hasUsableSnapshot: Bool {
        guard let snap = snapshot else { return false }
        return !snap.excerpt.isEmpty
    }

    private var headerText: String {
        guard hasUsableSnapshot, let snap = snapshot else { return "WHERE YOU STOPPED" }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let delta = max(0, nowMs - snap.generatedAtMs)
        return "WHERE YOU STOPPED · \(HomeRelativeTimeFormatter.format(deltaMs: delta, nowMs: nowMs))"
    }

    private var accessibilityHint: String {
        hasUsableSnapshot
            ? "Opens decisions, open questions, blockers, and where-stopped history."
            : "No recent stop-points. Opens full detector history."
    }
}
