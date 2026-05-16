//
//  LeafLinkedEventCard.swift
//  Track 5 / S7 B.7 — Atom for rendering an external attachment link.
//  Shows provider icon + title + status chip + meta line (full variant)
//  or icon + ref label + chevron (compact variant).
//
//  Consumed by LeafMessageCard (B.8) to surface cross-posted PR / Linear issue /
//  Slack thread beneath a DM body, and in Phase C attachment detail.
//
//  Design decisions:
//  - StatusColorKey → LeafPillTokens.Tone mapping lives here (UI layer)
//    so LeafCore (AttachmentMetadata) stays SwiftUI-free.
//  - Provider icons are SF Symbols; no custom Figma assets for external
//    brand logos in this iteration (branding risk, no asset yet).
//  - LeafType.body.regular for title — no bodyEmphasis token exists;
//    regular weight at 15pt reads as primary content at this size.
//

import SwiftUI
import LeafCore

struct LeafLinkedEventCard: View {

    enum Style { case compact, full }

    let metadata: AttachmentMetadata?
    let externalRef: String
    let provider: AttachmentProvider
    let style: Style
    let onTap: () -> Void

    init(
        metadata: AttachmentMetadata?,
        externalRef: String,
        provider: AttachmentProvider,
        style: Style,
        onTap: @escaping () -> Void
    ) {
        self.metadata = metadata
        self.externalRef = externalRef
        self.provider = provider
        self.style = style
        self.onTap = onTap
    }

    var body: some View {
        Group {
            switch style {
            case .full:    fullBody
            case .compact: compactBody
            }
        }
        .contentShape(.rect)
        .onTapGesture(perform: onTap)
    }

    // MARK: - Full variant

    private var fullBody: some View {
        LeafCard(variant: .raised) {
            HStack(alignment: .top, spacing: LeafSpace.sm) {
                providerIcon
                    .padding(.top, LeafSpace.xxs)   // optical alignment with first text line

                VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                    Text(metadata?.title ?? "Loading…")
                        .font(LeafType.body.regular)
                        .foregroundStyle(LeafColor.text.primary)
                        .lineLimit(LeafLinkedEventCardTokens.titleLineLimit)

                    if let metadata {
                        HStack(spacing: LeafSpace.xs) {
                            if let statusLabel = metadata.statusLabel {
                                LeafPill(title: statusLabel, tone: pillTone(metadata.statusColorKey))
                            }
                            Text("· \(metadata.authorDisplayName) · \(relativeTimestamp(metadata.createdAtMs))")
                                .font(LeafType.caption)
                                .foregroundStyle(LeafColor.text.tertiary)
                                .lineLimit(1)
                        }
                    } else {
                        // Loading state: dim ref label as placeholder
                        Text(externalRef)
                            .font(LeafType.caption)
                            .foregroundStyle(LeafColor.text.quaternary)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(LeafLinkedEventCardTokens.fullCardPadding)
        }
    }

    // MARK: - Compact variant

    private var compactBody: some View {
        HStack(spacing: LeafLinkedEventCardTokens.compactSpacing) {
            providerIcon
            Text(externalRef)
                .font(LeafType.caption)
                .foregroundStyle(LeafColor.text.tertiary)
            LeafIcon(systemName: "chevron.right", size: .sm, tint: LeafColor.text.quaternary)
        }
    }

    // MARK: - Provider icon

    private var providerIcon: some View {
        Image(systemName: providerSystemSymbol)
            .font(.system(size: LeafLinkedEventCardTokens.providerIconSize, weight: .regular))
            .foregroundStyle(providerIconColor)
            .frame(
                width: LeafLinkedEventCardTokens.providerIconSize,
                height: LeafLinkedEventCardTokens.providerIconSize
            )
    }

    private var providerSystemSymbol: String {
        switch provider {
        case .github: return "circle.dotted"
        case .linear: return "rectangle.stack"
        case .slack:  return "bubble.left.and.bubble.right.fill"
        }
    }

    private var providerIconColor: Color {
        LeafColor.text.tertiary
    }

    // MARK: - StatusColorKey → LeafPillTokens.Tone

    private func pillTone(_ key: StatusColorKey) -> LeafPillTokens.Tone {
        switch key {
        case .open:       return .accent
        case .closed:     return .neutral
        case .merged:     return .success
        case .inProgress: return .accent
        case .completed:  return .success
        case .blocked:    return .danger
        case .neutral:    return .neutral
        }
    }

    // MARK: - Relative timestamp

    private func relativeTimestamp(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
