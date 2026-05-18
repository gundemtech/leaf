//
//  InboxItemRow.swift
//  Track 8 / Phase 8.6 — INBOX item row. Severity dot leading edge,
//  title + sourceMeta lines. Tap-to-open + aggregation count added in
//  subsequent tasks (T7, T8).
//

import LeafCore
import SwiftUI

struct InboxItemRow: View {
    let item: InboxItem

    var body: some View {
        HStack(alignment: .top, spacing: LeafSpace.sm) {
            LeafDot(tone: dotTone, size: .md)
                .padding(.top, LeafSpace.xs)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                Text(item.title)
                    .font(LeafType.title.small)
                    .foregroundStyle(LeafColor.text.primary)
                    .lineLimit(2)
                Text(item.sourceMeta)
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(severityWord), \(item.title), \(item.sourceMeta)")
    }

    private var dotTone: LeafDotTone {
        switch item.severity {
        case .danger: return .danger
        case .warn: return .warning
        case .muted: return .muted
        }
    }

    private var severityWord: String {
        switch item.severity {
        case .danger: return "Urgent"
        case .warn: return "Needs response"
        case .muted: return "Informational"
        }
    }
}
