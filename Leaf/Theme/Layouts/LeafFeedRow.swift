//
//  LeafFeedRow.swift
//  Track 5 / S7 B.4 — Atom for compact auto-shared team event rows.
//  Team UI polish — resolved display names + muted typography so auto-shared
//  events read as ambient context while DMs stay the visual primary.
//
//  Two variants:
//    • Single — one TeamEventMirrorRow rendered as a 36pt compact row.
//    • Grouped — collapsed aggregate with count + timeline span; taps expand
//      to reveal individual child rows with indentation.
//
//  Design decisions:
//  - Source-kind SF Symbol mapping covers all 9 ShareSource cases; unknown
//    source degrades to "circle" rather than crashing.
//  - senderDisplayName is resolved by the caller (TeamMemberNameResolver) —
//    raw pubkey hex never reaches this view.
//  - actionText is a best-effort parser over payload JSON for the most common
//    event kinds. ADR-010 discipline: only allow-listed payload keys are read.
//  - attachmentMetadata is accepted but not rendered in this atom; reserved
//    for a future "feed detail" surface (Phase C/G).
//

import SwiftUI
import LeafCore

struct LeafFeedRow: View {

    let event: RenderedTeamEvent
    let senderDisplayName: String
    let attachmentMetadata: AttachmentMetadata?
    let onTap: () -> Void

    init(
        event: RenderedTeamEvent,
        senderDisplayName: String,
        attachmentMetadata: AttachmentMetadata?,
        onTap: @escaping () -> Void
    ) {
        self.event = event
        self.senderDisplayName = senderDisplayName
        self.attachmentMetadata = attachmentMetadata
        self.onTap = onTap
    }

    var body: some View {
        HStack(spacing: LeafSpace.sm) {
            Image(systemName: sourceKindSymbol(event.row.source))
                .font(.system(size: LeafFeedRowTokens.iconSize, weight: .regular))
                .foregroundStyle(LeafColor.text.tertiary)
                .frame(width: LeafFeedRowTokens.iconSize, height: LeafFeedRowTokens.iconSize)

            Text(senderDisplayName)
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.secondary)

            // M-IX — precomputed in the feed mapping layer (RenderedTeamEvent);
            // no JSON parse during render.
            Text(event.actionText)
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.tertiary)
                .lineLimit(1)

            Spacer()

            Text(relativeTimestamp(event.row.eventTsMs))
                .font(LeafType.caption)
                .foregroundStyle(LeafColor.text.tertiary)
        }
        .frame(height: LeafFeedRowTokens.rowHeight)
        .contentShape(.rect)
        .onTapGesture(perform: onTap)
    }

    // MARK: - Grouped variant

    /// Collapsed aggregate row + optionally expanded individual child rows.
    static func grouped(
        source: ShareSource,
        senderDisplayName: String,
        senderPubkeyHex: String,
        count: Int,
        spanStartMs: Int64,
        spanEndMs: Int64,
        expandedItems: [RenderedTeamEvent],
        isExpanded: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: LeafSpace.sm) {
                Image(systemName: sourceKindSymbol(source))
                    .font(.system(size: LeafFeedRowTokens.iconSize, weight: .regular))
                    .foregroundStyle(LeafColor.text.tertiary)
                    .frame(width: LeafFeedRowTokens.iconSize, height: LeafFeedRowTokens.iconSize)

                Text(senderDisplayName)
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.secondary)

                Text(groupedActionText(source: source, count: count))
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.tertiary)
                    .lineLimit(1)

                Spacer()

                Text(timelineSpan(startMs: spanStartMs, endMs: spanEndMs))
                    .font(LeafType.caption)
                    .foregroundStyle(LeafColor.text.tertiary)

                Image(systemName: "chevron.right")
                    .font(.system(size: LeafFeedRowTokens.iconSize, weight: .regular))
                    .foregroundStyle(LeafColor.text.tertiary)
                    .rotationEffect(isExpanded.wrappedValue ? LeafFeedRowTokens.chevronRotation : .zero)
            }
            .frame(height: LeafFeedRowTokens.rowHeight)
            .contentShape(.rect)
            .onTapGesture {
                withAnimation(LeafFeedRowTokens.expandAnimation) {
                    isExpanded.wrappedValue.toggle()
                }
            }

            if isExpanded.wrappedValue {
                VStack(alignment: .leading, spacing: LeafFeedRowTokens.groupedExpandedSpacing) {
                    ForEach(expandedItems) { item in
                        LeafFeedRow(
                            event: item,
                            senderDisplayName: senderDisplayName,
                            attachmentMetadata: nil,
                            onTap: {}
                        )
                        .padding(.leading, LeafSpace.lg)
                    }
                }
                .padding(.top, LeafSpace.xs)
            }
        }
    }
}

// MARK: - Private helpers

/// Maps ShareSource to SF Symbol name. Covers all 9 ShareSource cases.
/// Used by both the single-row variant (via row.source) and the grouped
/// factory (receives ShareSource directly).
private func sourceKindSymbol(_ source: ShareSource) -> String {
    switch source {
    case .gitCommits:            return "arrow.triangle.branch"
    case .linearIssues:          return "rectangle.stack"
    case .slackMentions:         return "bubble.left"
    case .githubPRs:             return "arrow.triangle.pull"
    case .detectedDecisions:     return "checkmark.circle"
    case .detectedBlockers:      return "exclamationmark.triangle"
    case .detectedOpenQuestions: return "questionmark.circle"
    case .detectedWhereStopped:  return "pause.circle"
    case .rawGitHubActivity:     return "doc.text"
    }
}

/// Grouped aggregate action text with count.
private func groupedActionText(source: ShareSource, count: Int) -> String {
    switch source {
    case .gitCommits:
        return "pushed \(count) commit\(count == 1 ? "" : "s")"
    case .linearIssues:
        return "\(count) issue update\(count == 1 ? "" : "s")"
    case .slackMentions:
        return "\(count) mention\(count == 1 ? "" : "s")"
    case .githubPRs:
        return "\(count) pull request\(count == 1 ? "" : "s")"
    case .detectedDecisions:
        return "\(count) decision\(count == 1 ? "" : "s")"
    case .detectedBlockers:
        return "\(count) blocker\(count == 1 ? "" : "s")"
    case .detectedOpenQuestions:
        return "\(count) open question\(count == 1 ? "" : "s")"
    case .detectedWhereStopped:
        return "\(count) where-stopped snapshot\(count == 1 ? "" : "s")"
    case .rawGitHubActivity:
        return "\(count) GitHub event\(count == 1 ? "" : "s")"
    }
}

/// Hoisted to file-level so per-row `body` rebuilds reuse one CFLocale +
/// formatter cache instead of allocating per row per render — long Team feed
/// scrolls were burning the entire CPU budget on `RelativeDateTimeFormatter`
/// init/teardown.
private let abbreviatedRelativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f
}()

/// Timeline span label "5m ago — 18m ago" using abbreviated relative format.
private func timelineSpan(startMs: Int64, endMs: Int64) -> String {
    let now = Date()
    let startDate = Date(timeIntervalSince1970: TimeInterval(startMs) / 1000)
    let endDate   = Date(timeIntervalSince1970: TimeInterval(endMs)   / 1000)
    let startStr  = abbreviatedRelativeFormatter.localizedString(for: startDate, relativeTo: now)
    let endStr    = abbreviatedRelativeFormatter.localizedString(for: endDate,   relativeTo: now)
    return "\(endStr) — \(startStr)"
}

/// Relative timestamp for a single event. Abbreviated format ("5m ago").
private func relativeTimestamp(_ ms: Int64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    return abbreviatedRelativeFormatter.localizedString(for: date, relativeTo: Date())
}
