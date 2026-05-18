//
//  InboxItemRow.swift
//  Track 8 / Phase 8.6 — INBOX item row. Severity dot leading edge,
//  title + sourceMeta lines, whole-row Button tap routes to
//  `NSWorkspace.shared.open(sourceURL)` when sourceURL non-nil.
//  Items with nil sourceURL (D3-derived open questions / blockers
//  pre-Phase 4.8/4.9 enrichment) render as inert informational rows.
//  Aggregation count suffix added in T8.
//

import AppKit
import LeafCore
import SwiftUI

struct InboxItemRow: View {
    let item: InboxItem

    var body: some View {
        Button(action: handleTap) {
            HStack(alignment: .top, spacing: LeafSpace.sm) {
                LeafDot(tone: dotTone, size: .md)
                    .padding(.top, LeafSpace.xs)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                    titleLine
                    Text(item.sourceMeta)
                        .font(LeafType.body.small)
                        .foregroundStyle(LeafColor.text.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(item.sourceURL == nil)
        .accessibilityLabel(a11yLabel)
        .accessibilityAddTraits(item.sourceURL == nil ? [] : .isButton)
    }

    private var titleLine: some View {
        HStack(spacing: LeafSpace.xxs) {
            Text(item.title)
                .font(LeafType.title.small)
                .foregroundStyle(LeafColor.text.primary)
                .lineLimit(2)
            if item.aggregatedCount > 1 {
                Text("(\(item.aggregatedCount))")
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.tertiary)
            }
        }
    }

    private func handleTap() {
        guard let url = item.sourceURL else { return }
        NSWorkspace.shared.open(url)
    }

    private var a11yLabel: String {
        let suffix = item.aggregatedCount > 1 ? " (\(item.aggregatedCount) similar)" : ""
        let action = item.sourceURL == nil ? "" : ", tap to open"
        return "\(severityWord), \(item.title)\(suffix), \(item.sourceMeta)\(action)"
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
