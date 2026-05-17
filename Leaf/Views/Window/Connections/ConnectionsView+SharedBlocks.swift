//
//  ConnectionsView+SharedBlocks.swift
//  Per-state visual blocks reused across providers (disconnected / progress /
//  connected / reconnect / error) + label helpers (relative "Just connected"
//  copy, Device Flow MM:SS countdown).
//

import Foundation
import SwiftUI
import LeafCore

extension ConnectionsView {

    // MARK: - Shared blocks

    func disconnectedBlock(
        title: String,
        description: String,
        ctaTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text(title)
                .font(LeafType.title.small)
                .foregroundStyle(LeafColor.text.primary)
            Text(description)
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.secondary)
            LeafButton(ctaTitle, variant: .primary, size: .md, action: action)
        }
    }

    func progressBlock(label: String) -> some View {
        HStack(spacing: LeafSpace.sm) {
            ProgressView().controlSize(.small)
            Text(label)
                .font(LeafType.body.regular)
                .foregroundStyle(LeafColor.text.secondary)
        }
    }

    func connectedBlock(
        title: String,
        connectedAt: Date,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: LeafSpace.md) {
            LeafDot(tone: .success, size: .md)
                .padding(.top, LeafSpace.xs)   // align with title baseline (xs = 4pt nudge)
            VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                Text(title)
                    .font(LeafType.title.small)
                    .foregroundStyle(LeafColor.text.primary)
                Text("\(connectedLabel(connectedAt: connectedAt)) · Polls every 5 min")
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.tertiary)
            }
            Spacer()
            LeafButton("Disconnect", variant: .destructive, size: .sm, action: action)
        }
    }

    func reconnectBlock(
        description: String,
        ctaTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            LeafIconLabel(
                icon: .asset(LeafIcons.status.warning),
                title: "Reconnect needed",
                iconTint: LeafColor.status.warning,
                titleStyle: LeafType.title.small
            )
            Text(description)
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.secondary)
            LeafButton(ctaTitle, variant: .primary, size: .md, action: action)
        }
    }

    func errorBlock(
        description: String,
        action: @escaping () -> Void
    ) -> some View {
        LeafBanner(
            tone: .danger,
            title: "Couldn't authenticate",
            description: description,
            ctaTitle: "Try again",
            onCTA: action
        )
    }

    // MARK: - Labels

    /// `RelativeDateTimeFormatter` для свежей даты возвращает "in 0 seconds" из-за
    /// nanosecond drift между timestamp создания row и rendered Date(). Под 5s
    /// ставим стабильный лейбл; выше — относительный formatter.
    func connectedLabel(connectedAt: Date) -> String {
        let elapsed = abs(Date().timeIntervalSince(connectedAt))
        if elapsed < 5 {
            return "Just connected"
        }
        return "Connected \(Self.relativeFormatter.localizedString(for: connectedAt, relativeTo: Date()))"
    }

    /// MM:SS countdown до истечения device_code (RFC 8628 §3.2 expiresIn).
    func countdownLabel(expiresAt: Date) -> String {
        let remaining = max(0, Int(expiresAt.timeIntervalSince(nowTick)))
        let minutes = remaining / 60
        let seconds = remaining % 60
        if remaining <= 0 {
            return "Code expired — try again."
        }
        return String(format: "Code expires in %d:%02d", minutes, seconds)
    }

    static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()
}
