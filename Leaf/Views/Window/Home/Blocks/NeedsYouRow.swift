//
//  NeedsYouRow.swift
//  Track 8 / Phase 8.6 — originally InboxItemRow. Severity dot leading
//  edge, title (+ inline `(N)` aggregation suffix when count > 1) +
//  sourceMeta line, whole-row Button tap routes to
//  `NSWorkspace.shared.open(sourceURL)` when sourceURL non-nil.
//  Items with nil sourceURL (D3-derived open questions / blockers
//  pre-Phase 4.8/4.9 enrichment) render as inert informational rows.
//  Track-10 T4 — struct + file renamed to NeedsYouRow for parity with
//  NeedsYouBlock. Logic unchanged.
//

import AppKit
import LeafCore
import SwiftUI

struct NeedsYouRow: View {
    let item: InboxItem

    var body: some View {
        Button(action: handleTap) {
            HStack(alignment: .top, spacing: LeafSpace.sm) {
                LeafDot(tone: dotTone, size: .md)
                    .padding(.top, LeafSpace.xs)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                    titleLine
                    HStack(spacing: LeafSpace.xs) {
                        Text(item.sourceMeta)
                            .font(LeafType.body.small)
                            .foregroundStyle(LeafColor.text.tertiary)
                            .lineLimit(1)
                        Text(Self.formatRelative(item.createdAtMs))
                            .font(LeafType.body.small)
                            .foregroundStyle(LeafColor.text.quaternary)
                    }
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Phase 8.9 a11y: dropped `.disabled(item.sourceURL == nil)` —
        // macOS removes disabled Buttons from the VoiceOver focus tree,
        // making informational rows (D3-derived items without sourceURL)
        // unreachable. `handleTap()` already guards on nil URL, so the
        // tap is a safe no-op without `.disabled`. The conditional
        // `.isButton` trait below keeps the trait off informational rows
        // so VoiceOver doesn't announce a non-interactive button.
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

    private static func formatRelative(_ tsMs: Int64) -> String {
        guard tsMs > 0 else { return "" }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if nowMs - tsMs < 60_000 { return "now" }
        let date = Date(timeIntervalSince1970: TimeInterval(tsMs) / 1000)
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
