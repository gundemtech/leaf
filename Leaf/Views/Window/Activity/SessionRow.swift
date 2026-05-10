//
//  SessionRow.swift
//  Track 2 / D3 — Activity row for one ActivitySession (continuous work block
//  in one app + window/file context). Migrated from old palette
//  (`.leafBody / .leafCaption / .leafInk / .leafMuted / .leafCategory(...)`)
//  to D1 substrate. Decorative category dot dropped per spec § OQ-6 — app
//  identity carries via real OS app icon (AppIconResolver) + app name.
//

import SwiftUI
import LeafCore

struct SessionRow: View {
    let session: ActivitySession

    var body: some View {
        LeafListRow(
            primary: AppNameResolver.shared.displayName(for: session.bundleID),
            secondary: contextLabel
        ) {
            iconView
                .frame(width: LeafSpace.xxl, height: LeafSpace.xxl)   // 32×32
        } trailing: {
            Text(formatDuration(session.duration))
                .font(LeafType.mono.small)
                .foregroundStyle(LeafColor.text.tertiary)
                .lineLimit(1)
        }
    }

    private var contextLabel: String? {
        guard let ctx = session.contextLabel else { return nil }
        let trimmed = ctx.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : ctx
    }

    @ViewBuilder
    private var iconView: some View {
        #if os(macOS)
        if let nsImage = AppIconResolver.shared.icon(for: session.bundleID, size: 32) {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
        } else {
            fallbackIcon
        }
        #else
        fallbackIcon
        #endif
    }

    private var fallbackIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: LeafRadius.sm, style: .continuous)
                .fill(LeafColor.surface.inset)
            LeafIcon(asset: LeafIcons.object.appPlaceholder, size: .sm, tint: LeafColor.text.tertiary)
        }
    }

    private func formatDuration(_ s: TimeInterval) -> String {
        let total = Int(s.rounded())
        if total < 60 { return "\(total)s" }
        let m = total / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60, rm = m % 60
        return rm == 0 ? "\(h)h" : "\(h)h \(rm)m"
    }
}
