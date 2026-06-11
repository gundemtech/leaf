//
//  SearchView.swift
//  UC-1 — in-app search over the local memory: decisions first, then open
//  questions / blockers, then raw FTS event matches. Same QueryEngine the
//  MCP tools use; this is the native surface for "find the thread that
//  explains why" without an AI client.
//
//  Track B-UI: result cards follow the landing-page terminal-card pattern —
//  "● decision · 2 weeks ago" header + MATCH badge on the top result +
//  AUTHOR / CHANNEL / COMMIT / TICKET / PR label-value grid.
//

import LeafCore
import SwiftUI

struct SearchView: View {
  @State private var reader = SearchReader()
  @State private var query: String = ""

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: LeafSpace.xl) {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
          Text("SEARCH YOUR MEMORY")
            .leafSectionLabel()
            .foregroundStyle(LeafColor.text.tertiary)
            .accessibilityAddTraits(.isHeader)

          HStack(spacing: LeafSpace.md) {
            LeafInput(
              text: $query,
              placeholder: "Search decisions, commits, threads…",
              prefixIcon: .system(LeafIcons.nav.searchSF)
            )
            if case .results(let presentation) = reader.state {
              Text(presentation.countLabel)
                .font(LeafType.mono.small)
                .foregroundStyle(LeafColor.text.tertiary)
                .fixedSize()
            }
          }
        }

        content
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(LeafSpace.xl)
    }
    // Debounce: re-fires on every keystroke, sleeps 300ms; superseded
    // tasks are cancelled by SwiftUI, stale results dropped by the reader's
    // generation counter.
    .task(id: query) {
      guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
        reader.reset()
        return
      }
      try? await Task.sleep(nanoseconds: 300_000_000)
      guard !Task.isCancelled else { return }
      await reader.search(query: query)
    }
  }

  @ViewBuilder
  private var content: some View {
    switch reader.state {
    case .idle:
      LeafEmptyState(
        icon: LeafIcons.brand.leaf,
        title: "Search everything Leaf remembers.",
        description:
          "Decisions, commit messages, issue updates, threads — captured locally on this Mac."
      )
    case .searching:
      HStack(spacing: LeafSpace.sm) {
        ProgressView().controlSize(.small)
        Text("Searching…")
          .font(LeafType.body.small)
          .foregroundStyle(LeafColor.text.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.top, LeafSpace.xl)
    case .empty:
      LeafEmptyState(
        icon: LeafIcons.nav.searchSF,
        title: "No matches in the last 90 days.",
        description: "Try different keywords — search covers text Leaf captured locally."
      )
    case .error(let message):
      LeafEmptyState(
        icon: LeafIcons.brand.leaf,
        title: "Search unavailable",
        description: message
      )
    case .results(let presentation):
      resultsList(presentation)
    }
  }

  @ViewBuilder
  private func resultsList(_ presentation: SearchResultsPresentation) -> some View {
    LazyVStack(alignment: .leading, spacing: LeafSpace.md) {
      ForEach(presentation.rows) { row in
        resultCard(row, isTopMatch: row.id == presentation.topMatchID)
      }
    }
  }

  @ViewBuilder
  private func resultCard(_ row: SearchResultRow, isTopMatch: Bool) -> some View {
    LeafCard(padding: .regular) {
      VStack(alignment: .leading, spacing: LeafSpace.md) {
        LeafTerminalCardHeader(
          dotTone: dotTone(row.kind),
          title: headerTitle(row)
        ) {
          if isTopMatch {
            LeafStatusBadge(text: "MATCH")
          }
        }

        Text(row.title)
          .font(LeafType.title.small)
          .foregroundStyle(LeafColor.text.primary)
          .lineLimit(3)
          .truncationMode(.tail)

        if let excerpt = row.excerpt {
          Text(excerpt)
            .font(LeafType.body.small)
            .foregroundStyle(LeafColor.text.secondary)
            .lineLimit(2)
            .truncationMode(.tail)
        }

        if !row.detailRows.isEmpty {
          VStack(alignment: .leading, spacing: LeafSpace.sm) {
            ForEach(row.detailRows) { detail in
              LeafLabelValueRow(
                label: detail.label.rawValue,
                value: detail.value,
                accentPrefix: accentPrefix(for: detail),
                url: detail.url
              )
            }
          }
          .padding(.top, LeafSpace.xs)
        }

        if row.detailRows.isEmpty, !row.links.isEmpty {
          // Fallback trail for rows without composed detail lines.
          HStack(spacing: LeafSpace.xs) {
            ForEach(Array(row.links.prefix(4).enumerated()), id: \.offset) { _, link in
              LeafPill(title: link.targetRef, tone: .accent)
            }
          }
        }

        HStack(spacing: LeafSpace.xs) {
          Text(row.sourceLabel)
            .font(LeafType.mono.small)
            .foregroundStyle(LeafColor.text.tertiary)
          Text(Self.formatRelative(row.tsMs))
            .font(LeafType.mono.small)
            .foregroundStyle(LeafColor.text.quaternary)
          if row.occurrenceCount > 1 {
            Text("×\(row.occurrenceCount)")
              .font(LeafType.mono.small)
              .foregroundStyle(LeafColor.text.quaternary)
          }
        }
      }
    }
    .accessibilityElement(children: .combine)
  }

  /// "decision · 2 weeks ago" — mono lowercase header per the mockup.
  private func headerTitle(_ row: SearchResultRow) -> String {
    let kindLabel: String
    switch row.kind {
    case .decision: kindLabel = "decision"
    case .openQuestion: kindLabel = "open question"
    case .blocker: kindLabel = "blocker"
    case .event: kindLabel = row.sourceLabel.lowercased()
    }
    let relative = Self.formatRelative(row.tsMs)
    return relative.isEmpty ? kindLabel : "\(kindLabel) · \(relative)"
  }

  /// Green accent segments: ticket/PR refs and conventional-commit prefixes.
  private func accentPrefix(for detail: SearchResultDetailRow) -> String? {
    switch detail.label {
    case .commit:
      if let colon = detail.value.firstIndex(of: ":") {
        return String(detail.value[detail.value.startIndex...colon])
      }
      return nil
    case .ticket, .pr:
      return detail.value
    case .author, .channel, .outcome, .thread:
      return nil
    }
  }

  private func dotTone(_ kind: SearchResultRow.Kind) -> LeafDotTone {
    switch kind {
    case .decision: return .success
    case .openQuestion: return .warning
    case .blocker: return .danger
    case .event: return .muted
    }
  }

  private static func formatRelative(_ tsMs: Int64) -> String {
    guard tsMs > 0 else { return "" }
    let date = Date(timeIntervalSince1970: TimeInterval(tsMs) / 1000)
    return relativeFormatter.localizedString(for: date, relativeTo: Date())
  }

  private static let relativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f
  }()
}
