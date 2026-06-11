//
//  SearchView.swift
//  UC-1 — in-app search over the local memory: decisions first, then open
//  questions / blockers, then raw FTS event matches. Same QueryEngine the
//  MCP tools use; this is the native surface for "find the thread that
//  explains why" without an AI client.
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

          LeafInput(
            text: $query,
            placeholder: "Search decisions, commits, threads…",
            prefixIcon: .system(LeafIcons.nav.searchSF)
          )
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
    case .results(let rows):
      resultsList(rows)
    }
  }

  @ViewBuilder
  private func resultsList(_ rows: [SearchResultRow]) -> some View {
    LeafCard(padding: .regular) {
      LazyVStack(alignment: .leading, spacing: LeafSpace.md) {
        ForEach(rows) { row in
          resultRow(row)
          if row.id != rows.last?.id {
            LeafDivider()
          }
        }
      }
    }
  }

  @ViewBuilder
  private func resultRow(_ row: SearchResultRow) -> some View {
    HStack(alignment: .top, spacing: LeafSpace.sm) {
      LeafDot(tone: dotTone(row.kind), size: .md)
        .padding(.top, LeafSpace.xs)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: LeafSpace.xxs) {
        Text(row.title)
          .font(LeafType.title.small)
          .foregroundStyle(LeafColor.text.primary)
          .lineLimit(2)
          .truncationMode(.tail)

        if let excerpt = row.excerpt {
          Text(excerpt)
            .font(LeafType.body.small)
            .foregroundStyle(LeafColor.text.secondary)
            .lineLimit(2)
            .truncationMode(.tail)
        }

        HStack(spacing: LeafSpace.xs) {
          Text(row.sourceLabel)
            .font(LeafType.body.small)
            .foregroundStyle(LeafColor.text.tertiary)
          Text(Self.formatRelative(row.tsMs))
            .font(LeafType.body.small)
            .foregroundStyle(LeafColor.text.quaternary)
          if row.occurrenceCount > 1 {
            Text("×\(row.occurrenceCount)")
              .font(LeafType.body.small)
              .foregroundStyle(LeafColor.text.quaternary)
          }
        }

        if !row.links.isEmpty {
          // Outbound links of the originating event — the "where it landed"
          // trail (PR / issue / thread refs).
          HStack(spacing: LeafSpace.xs) {
            ForEach(Array(row.links.prefix(4).enumerated()), id: \.offset) { _, link in
              LeafPill(title: link.targetRef, tone: .accent)
            }
          }
          .padding(.top, LeafSpace.xxs)
        }
      }
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
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
