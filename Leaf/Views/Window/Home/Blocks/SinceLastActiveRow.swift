//
//  SinceLastActiveRow.swift
//  Track-10 T5 — per-item row renderer for SINCE YOU WERE LAST ACTIVE timeline.
//  Mirrors NeedsYouRow shape (severity dot + actor/verb/target line + sourceMeta
//  caption + relative-age caption) with tap-to-open sourceURL semantic.
//
//  Body fields never read (ADR-010 walkback enforced at substrate boundary —
//  sentinel-injection regression in RelayBodyLeakageTests covers feed read path).
//

import AppKit
import LeafCore
import SwiftUI

struct SinceLastActiveRow: View {
    let item: SinceLastActiveItem

    var body: some View {
        Button(action: handleTap) {
            HStack(alignment: .top, spacing: LeafSpace.sm) {
                LeafDot(tone: dotTone, size: .md)
                    .padding(.top, LeafSpace.xs)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                    titleLine
                    metaLine
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(a11yLabel)
        .accessibilityAddTraits(item.sourceURL == nil ? [] : .isButton)
    }

    private var titleLine: some View {
        HStack(spacing: LeafSpace.xxs) {
            if !item.actorPrefix.isEmpty {
                Text(item.actorPrefix)
                    .font(LeafType.title.small)
                    .foregroundStyle(LeafColor.text.primary)
            }
            Text(item.verb)
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.secondary)
            Text(item.targetTitle)
                .font(LeafType.title.small)
                .foregroundStyle(LeafColor.text.primary)
                .lineLimit(1)
        }
    }

    private var metaLine: some View {
        HStack(spacing: LeafSpace.xs) {
            if !item.sourceMeta.isEmpty {
                Text(item.sourceMeta)
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.tertiary)
                    .lineLimit(1)
            }
            Text(Self.formatRelative(item.tsMs))
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.tertiary)
        }
    }

    private func handleTap() {
        guard let url = item.sourceURL else { return }
        NSWorkspace.shared.open(url)
    }

    private var dotTone: LeafDotTone {
        switch item.severity {
        case .danger: return .danger
        case .warn: return .warning
        case .muted: return .muted
        }
    }

    private var a11yLabel: String {
        let prefix = item.actorPrefix.isEmpty ? "" : "\(item.actorPrefix) "
        let action = item.sourceURL == nil ? "" : ", tap to open"
        return
            "\(prefix)\(item.verb) \(item.targetTitle), \(item.sourceMeta), \(Self.formatRelative(item.tsMs))\(action)"
    }

    // T1 carry — "<1m" renders as "now" (T1 line-249 master spec rule).
    // Extract to shared helper once a third block adopts (carry C-T5-9).
    private static func formatRelative(_ tsMs: Int64) -> String {
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
