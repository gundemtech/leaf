//
//  LeafTerminalCard.swift
//  Use-case rebuild Track B-UI — shared "terminal card" vocabulary matching
//  the landing-page mockups: dot + mono-lowercase header with a right badge
//  slot, label-value rows with a fixed mono label column, big-figure count
//  rows, and a mono footer link. Used by Brief / Search / Nudges / Handoff
//  surfaces so the four cards read as one family.
//

import SwiftUI

// MARK: - Header

/// "● monday brief ······························ [badge]" + hairline below.
struct LeafTerminalCardHeader<Badge: View>: View {
  let dotTone: LeafDotTone
  let title: String
  /// Right-aligned secondary text ("last 5 days") — shown left of the badge.
  var detail: String? = nil
  @ViewBuilder var badge: () -> Badge

  var body: some View {
    VStack(alignment: .leading, spacing: LeafSpace.sm) {
      HStack(spacing: LeafSpace.sm) {
        LeafDot(tone: dotTone, size: .md)
          .accessibilityHidden(true)
        Text(title)
          .font(LeafType.mono.regular)
          .foregroundStyle(LeafColor.text.primary)
          .lineLimit(1)
        Spacer(minLength: LeafSpace.sm)
        if let detail {
          Text(detail)
            .font(LeafType.mono.small)
            .foregroundStyle(LeafColor.text.tertiary)
        }
        badge()
      }
      LeafDivider()
    }
  }
}

extension LeafTerminalCardHeader where Badge == EmptyView {
  init(dotTone: LeafDotTone, title: String, detail: String? = nil) {
    self.init(dotTone: dotTone, title: title, detail: detail) { EmptyView() }
  }
}

// MARK: - Status badge

/// Mockup capsule badges: `live` / `MATCH` / `PICKING UP` (green outline),
/// `3 NUDGES` (warning), `ready`.
struct LeafStatusBadge: View {
  enum Tone {
    case accent, warning

    var color: Color {
      switch self {
      case .accent: LeafColor.status.success
      case .warning: LeafColor.status.warning
      }
    }
  }

  let text: String
  var tone: Tone = .accent
  /// Leading dot inside the capsule ("● live").
  var showDot: Bool = false

  var body: some View {
    HStack(spacing: LeafSpace.xs) {
      if showDot {
        Circle()
          .fill(tone.color)
          .frame(width: 5, height: 5)
      }
      Text(text)
        .font(LeafType.mono.small)
        .foregroundStyle(tone.color)
    }
    .padding(.horizontal, LeafSpace.sm)
    .padding(.vertical, LeafSpace.xxs)
    .overlay(
      Capsule().strokeBorder(tone.color.opacity(0.45), lineWidth: 1)
    )
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Label-value row

/// "LAST COMMIT   feat: token rotation · 2h ago" — fixed-width mono label
/// column, optional glowing dot, value with optional green accent prefix.
struct LeafLabelValueRow: View {
  let label: String
  let value: String
  /// Leading segment of `value` rendered in the accent color ("feat:",
  /// "a3f2"). Must be an actual prefix of `value` to take effect.
  var accentPrefix: String? = nil
  var showDot: Bool = false
  var url: URL? = nil

  private static let labelColumnWidth: CGFloat = 104

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: LeafSpace.sm) {
      if showDot {
        Circle()
          .fill(LeafColor.status.success)
          .frame(width: 6, height: 6)
          .shadow(color: LeafColor.status.success.opacity(0.8), radius: 3)
          .accessibilityHidden(true)
      }
      Text(label)
        .font(LeafType.mono.small)
        .foregroundStyle(LeafColor.text.tertiary)
        .frame(width: Self.labelColumnWidth, alignment: .leading)
      valueText
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private var valueText: some View {
    let base = styledValue
    if let url {
      Link(destination: url) { base }
        .buttonStyle(.plain)
    } else {
      base
    }
  }

  private var styledValue: Text {
    if let accentPrefix, value.hasPrefix(accentPrefix) {
      return Text(accentPrefix)
        .font(LeafType.mono.small)
        .foregroundColor(LeafColor.status.success)
        + Text(String(value.dropFirst(accentPrefix.count)))
        .font(LeafType.mono.small)
        .foregroundColor(LeafColor.text.primary)
    }
    return Text(value)
      .font(LeafType.mono.small)
      .foregroundColor(LeafColor.text.primary)
  }
}

// MARK: - Count figure

/// "12  PRs merged across 4 repos" — big mono number + caption, with an
/// optional green keyword segment ("done").
struct LeafCountFigure: View {
  let count: Int
  let text: String
  var accentWord: String? = nil

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: LeafSpace.md) {
      Text("\(count)")
        .font(LeafType.mono.large)
        .foregroundStyle(LeafColor.text.primary)
        .frame(minWidth: 36, alignment: .trailing)
      caption
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
  }

  private var caption: Text {
    guard let accentWord, let range = text.range(of: accentWord) else {
      return Text(text)
        .font(LeafType.body.regular)
        .foregroundColor(LeafColor.text.secondary)
    }
    let head = String(text[text.startIndex..<range.lowerBound])
    let tail = String(text[range.upperBound...])
    return Text(head).font(LeafType.body.regular).foregroundColor(LeafColor.text.secondary)
      + Text(accentWord).font(LeafType.body.regular).foregroundColor(LeafColor.status.success)
      + Text(tail).font(LeafType.body.regular).foregroundColor(LeafColor.text.secondary)
  }
}

// MARK: - Footer link

/// "······························ read full brief →" with an optional left
/// tertiary note ("visible only to you · no manager dashboard").
struct LeafCardFooterLink: View {
  var note: String? = nil
  let title: String
  let action: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: LeafSpace.sm) {
      LeafDivider()
      HStack {
        if let note {
          Text(note)
            .font(LeafType.mono.small)
            .foregroundStyle(LeafColor.text.quaternary)
        }
        Spacer(minLength: LeafSpace.sm)
        Button(action: action) {
          Text("\(title) →")
            .font(LeafType.mono.small)
            .foregroundStyle(LeafColor.status.success)
        }
        .buttonStyle(.plain)
      }
    }
  }
}
