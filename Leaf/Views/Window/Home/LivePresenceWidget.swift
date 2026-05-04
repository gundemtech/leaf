import SwiftUI
import LeafCore

/// Phase 4.10.A — Live Presence widget on the Home dashboard.
/// Renders the current `presence_state` snapshot (Phase 4.7.B substrate) as
/// a 3-column row of GitHub / Linear / Slack mini-cards. Provider columns
/// missing rows render an empty state with a "Connect" hint.
struct LivePresenceWidget: View {
    let snapshot: PresenceUISnapshot

    var body: some View {
        GlassCard(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                Text("RIGHT NOW")
                    .leafLabelStyle()
                if snapshot.isEmpty {
                    Text("Connect Linear, GitHub, or Slack to see live presence here.")
                        .font(.leafBody)
                        .foregroundStyle(.leafMuted)
                } else {
                    HStack(alignment: .top, spacing: 24) {
                        column(
                            title: "GITHUB",
                            lines: githubLines,
                            connected: snapshot.github != nil
                        )
                        Divider().frame(maxHeight: 80)
                        column(
                            title: "LINEAR",
                            lines: linearLines,
                            connected: snapshot.linear != nil
                        )
                        Divider().frame(maxHeight: 80)
                        column(
                            title: "SLACK",
                            lines: slackLines,
                            connected: snapshot.slack != nil
                        )
                    }
                }
            }
        }
    }

    // MARK: - Columns

    private func column(title: String, lines: [PresenceLine], connected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.leafCaption)
                .foregroundStyle(.leafMuted)
                .kerning(0.6)
            if !connected {
                Text("Not connected")
                    .font(.leafBody)
                    .foregroundStyle(.leafMuted)
            } else if lines.isEmpty {
                Text("All quiet.")
                    .font(.leafBody)
                    .foregroundStyle(.leafMuted)
            } else {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(spacing: 6) {
                        Image(systemName: line.symbol)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(line.tint)
                            .frame(width: 14)
                        Text(line.text)
                            .font(.leafBody)
                            .foregroundStyle(.leafInk)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Lines per provider

    private struct PresenceLine {
        let symbol: String
        let text: String
        let tint: Color
    }

    private var githubLines: [PresenceLine] {
        guard let g = snapshot.github else { return [] }
        var lines: [PresenceLine] = []
        if g.prsAwaitingMyReview > 0 {
            lines.append(.init(
                symbol: "eye",
                text: "\(g.prsAwaitingMyReview) PR\(g.prsAwaitingMyReview == 1 ? "" : "s") awaiting review",
                tint: .leafAccentDeep
            ))
        }
        if g.myOpenPRs > 0 {
            lines.append(.init(
                symbol: "arrow.triangle.pull",
                text: "\(g.myOpenPRs) of mine open",
                tint: .leafInk.opacity(0.6)
            ))
        }
        if g.notificationsUnread > 0 {
            lines.append(.init(
                symbol: "bell",
                text: "\(g.notificationsUnread) unread",
                tint: .leafInk.opacity(0.6)
            ))
        }
        if let status = g.latestPushCheckStatus {
            let (sym, tint) = checkRunSymbol(status)
            lines.append(.init(symbol: sym, text: "checks: \(status)", tint: tint))
        }
        return lines
    }

    private var linearLines: [PresenceLine] {
        guard let l = snapshot.linear else { return [] }
        var lines: [PresenceLine] = []
        if l.startedIssuesCount > 0 {
            lines.append(.init(
                symbol: "play.circle",
                text: "\(l.startedIssuesCount) issue\(l.startedIssuesCount == 1 ? "" : "s") started",
                tint: .leafAccentDeep
            ))
        }
        if l.topPriority != "none" {
            let (sym, tint) = priorityVisuals(l.topPriority)
            lines.append(.init(symbol: sym, text: "top: \(l.topPriority)", tint: tint))
        }
        if let cycleName = l.cycleName, let pct = l.cycleCompletedPct {
            let days = l.cycleDaysRemaining
            let suffix = days.map { " · \($0)d left" } ?? ""
            lines.append(.init(
                symbol: "circle.lefthalf.filled",
                text: "\(cycleName) · \(pct)%\(suffix)",
                tint: .leafInk.opacity(0.6)
            ))
        }
        return lines
    }

    private var slackLines: [PresenceLine] {
        guard let s = snapshot.slack else { return [] }
        var lines: [PresenceLine] = []
        if s.dndActive {
            lines.append(.init(
                symbol: "moon",
                text: "Do not disturb",
                tint: .leafSignal
            ))
        } else {
            let presenceLabel: String
            let tint: Color
            switch s.nativePresence {
            case "active": presenceLabel = "Active"; tint = .leafAccentDeep
            case "away":   presenceLabel = "Away";   tint = .leafMuted
            default:       presenceLabel = "Unknown"; tint = .leafMuted
            }
            lines.append(.init(symbol: "circle.fill", text: presenceLabel, tint: tint))
        }
        if s.inHuddle {
            lines.append(.init(symbol: "person.wave.2", text: "In a huddle", tint: .leafAccentDeep))
        }
        if s.mentionsToday > 0 {
            lines.append(.init(
                symbol: "at",
                text: "\(s.mentionsToday) mention\(s.mentionsToday == 1 ? "" : "s") today",
                tint: .leafInk.opacity(0.6)
            ))
        }
        if let emoji = s.statusEmoji {
            lines.append(.init(symbol: "face.smiling", text: emoji, tint: .leafInk.opacity(0.6)))
        }
        return lines
    }

    // MARK: - Helpers

    private func checkRunSymbol(_ status: String) -> (String, Color) {
        switch status.lowercased() {
        case "success", "passing": return ("checkmark.circle", .leafAccentDeep)
        case "failure", "failing": return ("xmark.octagon", .leafSignal)
        case "in_progress":        return ("clock", .leafInk.opacity(0.6))
        default:                   return ("questionmark.circle", .leafMuted)
        }
    }

    private func priorityVisuals(_ priority: String) -> (String, Color) {
        switch priority.lowercased() {
        case "urgent": return ("exclamationmark.octagon.fill", .leafSignal)
        case "high":   return ("exclamationmark.triangle.fill", .leafAccentDeep)
        case "normal": return ("equal.circle", .leafInk.opacity(0.6))
        case "low":    return ("arrow.down.circle", .leafMuted)
        default:       return ("circle", .leafMuted)
        }
    }
}
