//
//  LeafIconChipPreview.swift
//  Track 2 / D1 — TokensPreview entry for Atom A5 LeafIconChip.
//

import SwiftUI

#if DEBUG
struct LeafIconChipPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("LeafIconChip")
                .font(LeafType.title.medium)
                .foregroundStyle(LeafColor.text.primary)

            // Sizes — sm / md / lg.
            HStack(alignment: .center, spacing: LeafSpace.lg) {
                row(size: .sm, label: "sm · 24")
                row(size: .md, label: "md · 32")
                row(size: .lg, label: "lg · 40")
            }

            // Tones — info / success / warning / danger / neutral.
            HStack(alignment: .center, spacing: LeafSpace.md) {
                LeafIconChip(asset: LeafIcons.status.info,         tint: LeafColor.status.info)
                LeafIconChip(asset: LeafIcons.status.successFill,  tint: LeafColor.status.success)
                LeafIconChip(asset: LeafIcons.status.warningFill,  tint: LeafColor.status.warning)
                LeafIconChip(asset: LeafIcons.status.warningFill,  tint: LeafColor.status.danger)
                LeafIconChip(asset: LeafIcons.action.close,        tint: LeafColor.text.tertiary)
            }

            TokensInlineSpec(
                spec: "LeafIconChip · sm 24 / md 32 / lg 40 / xl 64 squircle · tint glyph + tint @ 0.15 background · LeafRadius.sm/md/lg/xl corners",
                codeSnippet: "LeafIconChip(asset: LeafIcons.status.info, tint: LeafColor.status.info)"
            )
        }
        .padding(LeafSpace.lg)
        .background(LeafColor.surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
    }

    @ViewBuilder
    private func row(size: LeafIconChipTokens.Size, label: String) -> some View {
        VStack(spacing: LeafSpace.xs) {
            LeafIconChip(asset: LeafIcons.status.info, size: size, tint: LeafColor.accent.primary)
            Text(label)
                .font(LeafType.mono.small)
                .foregroundStyle(LeafColor.text.tertiary)
        }
    }
}
#endif
