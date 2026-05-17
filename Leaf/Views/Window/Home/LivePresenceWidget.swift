//
//  LivePresenceWidget.swift
//  Track 2 / D2 — Home Section 2 "RIGHT NOW". Renders presence_state
//  (Phase 4.7.B substrate) as 3 columns inside a LeafCard with vertical
//  hairline dividers between providers.
//
//  Tint discipline (D1 § "Color is a signal, not a wash"):
//    accent.primary  — needs attention (PRs awaiting review, started issues)
//    status.success  — passing checks
//    status.danger   — DND, failing checks, urgent priority
//    status.warning  — high priority
//    text.tertiary   — informational counts and ambient state
//
//  Tries to feel the way a Linear-style scanning grid does — minimalist,
//  vertical separators, monospaced inline counts, no card chrome inside
//  columns.
//

import LeafCore
import SwiftUI

struct LivePresenceWidget: View {
    let snapshot: PresenceUISnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("RIGHT NOW")
                .leafSectionLabel()
                .foregroundStyle(LeafColor.text.tertiary)

            LeafCard(padding: .regular) {
                HStack(alignment: .top, spacing: LeafSpace.xl) {
                    column(title: "GITHUB", lines: githubLines, connected: snapshot.github != nil)
                    verticalDivider
                    column(title: "LINEAR", lines: linearLines, connected: snapshot.linear != nil)
                    verticalDivider
                    column(title: "SLACK", lines: slackLines, connected: snapshot.slack != nil)
                }
            }
        }
    }

    // MARK: - Vertical divider

    /// LeafDivider (Atom A3) is horizontal-only. Vertical hairline is a
    /// 1pt-wide Rectangle filled with LeafColor.border.subtle — same colour
    /// token, just rotated. Height bounded so columns of unequal lines
    /// don't visually anchor on the divider.
    private var verticalDivider: some View {
        Rectangle()
            .fill(LeafColor.border.subtle)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
    }

    // MARK: - Column

    @ViewBuilder
    private func column(title: String, lines: [PresenceLine], connected: Bool) -> some View {
        VStack(alignment: .leading, spacing: LeafSpace.xs) {
            Text(title)
                .leafSectionLabel()
                .foregroundStyle(LeafColor.accent.primary.opacity(0.6))

            if !connected {
                Text("Not connected")
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.tertiary)
            } else if lines.isEmpty {
                Text("All quiet")
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.tertiary)
            } else {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    LeafIconLabel(
                        icon: .system(line.symbol),
                        title: line.text,
                        iconTint: line.tint,
                        titleStyle: LeafType.body.small
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Lines

    private struct PresenceLine {
        let symbol: String
        let text: String
        let tint: Color
    }

    private var githubLines: [PresenceLine] {
        guard let g = snapshot.github else { return [] }
        var lines: [PresenceLine] = []
        if g.prsAwaitingMyReview > 0 {
            lines.append(
                .init(
                    symbol: "eye",
                    text: "\(g.prsAwaitingMyReview) PR\(g.prsAwaitingMyReview == 1 ? "" : "s") await your review",
                    tint: LeafColor.accent.primary
                ))
        }
        if g.myOpenPRs > 0 {
            lines.append(
                .init(
                    symbol: "arrow.triangle.pull",
                    text: "\(g.myOpenPRs) of mine open",
                    tint: LeafColor.text.tertiary
                ))
        }
        if g.notificationsUnread > 0 {
            lines.append(
                .init(
                    symbol: "bell",
                    text: "\(g.notificationsUnread) unread",
                    tint: LeafColor.text.tertiary
                ))
        }
        if let status = g.latestPushCheckStatus {
            let (sym, tint) = checkRunVisuals(status)
            lines.append(.init(symbol: sym, text: "checks: \(status)", tint: tint))
        }
        return lines
    }

    private var linearLines: [PresenceLine] {
        guard let l = snapshot.linear else { return [] }
        var lines: [PresenceLine] = []
        if l.startedIssuesCount > 0 {
            lines.append(
                .init(
                    symbol: "play.circle",
                    text: "\(l.startedIssuesCount) issue\(l.startedIssuesCount == 1 ? "" : "s") started",
                    tint: LeafColor.accent.primary
                ))
        }
        if l.topPriority != "none" {
            let (sym, tint) = priorityVisuals(l.topPriority)
            lines.append(.init(symbol: sym, text: "top: \(l.topPriority)", tint: tint))
        }
        if let cycleName = l.cycleName, let pct = l.cycleCompletedPct {
            let suffix = l.cycleDaysRemaining.map { " · \($0)d left" } ?? ""
            lines.append(
                .init(
                    symbol: "circle.lefthalf.filled",
                    text: "\(cycleName) · \(pct)%\(suffix)",
                    tint: LeafColor.text.tertiary
                ))
        }
        return lines
    }

    private var slackLines: [PresenceLine] {
        guard let s = snapshot.slack else { return [] }
        var lines: [PresenceLine] = []
        if s.dndActive {
            lines.append(.init(symbol: "moon", text: "Do not disturb", tint: LeafColor.status.danger))
        } else {
            switch s.nativePresence {
            case "active":
                lines.append(.init(symbol: "circle.fill", text: "Active", tint: LeafColor.accent.primary))
            case "away":
                lines.append(.init(symbol: "circle.fill", text: "Away", tint: LeafColor.text.tertiary))
            default:
                lines.append(.init(symbol: "circle.fill", text: "Unknown", tint: LeafColor.text.tertiary))
            }
        }
        if s.inHuddle {
            lines.append(
                .init(
                    symbol: "person.wave.2",
                    text: "In a huddle",
                    tint: LeafColor.accent.primary
                ))
        }
        if s.mentionsToday > 0 {
            lines.append(
                .init(
                    symbol: "at",
                    text: "\(s.mentionsToday) mention\(s.mentionsToday == 1 ? "" : "s") today",
                    tint: LeafColor.text.tertiary
                ))
        }
        if let emoji = s.statusEmoji {
            lines.append(
                .init(
                    symbol: "face.smiling",
                    text: emoji,
                    tint: LeafColor.text.tertiary
                ))
        }
        return lines
    }

    // MARK: - Visual helpers

    private func checkRunVisuals(_ status: String) -> (String, Color) {
        switch status.lowercased() {
        case "success", "passing": return ("checkmark.circle", LeafColor.status.success)
        case "failure", "failing": return ("xmark.octagon", LeafColor.status.danger)
        case "in_progress": return ("clock", LeafColor.text.tertiary)
        default: return ("questionmark.circle", LeafColor.text.tertiary)
        }
    }

    private func priorityVisuals(_ priority: String) -> (String, Color) {
        switch priority.lowercased() {
        case "urgent": return ("exclamationmark.octagon.fill", LeafColor.status.danger)
        case "high": return ("exclamationmark.triangle.fill", LeafColor.status.warning)
        case "normal": return ("equal.circle", LeafColor.text.tertiary)
        case "low": return ("arrow.down.circle", LeafColor.text.tertiary)
        default: return ("circle", LeafColor.text.tertiary)
        }
    }
}
