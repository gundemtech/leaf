//
//  TokensColorSection.swift
//  Track 2 / D1 — Preview swatches for LeafColor.* surface/text/accent/status/border.
//

import SwiftUI

#if DEBUG
struct TokensColorSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.lg) {
            sectionTitle("Color")
            group(
                "Surface",
                swatches: [
                    ("canvas", LeafColor.surface.canvas),
                    ("raised", LeafColor.surface.raised),
                    ("inset", LeafColor.surface.inset),
                ])
            group(
                "Text",
                swatches: [
                    ("primary", LeafColor.text.primary),
                    ("secondary", LeafColor.text.secondary),
                    ("tertiary", LeafColor.text.tertiary),
                    ("quaternary", LeafColor.text.quaternary),
                    ("inverse", LeafColor.text.inverse),
                ])
            group(
                "Accent",
                swatches: [
                    ("primary", LeafColor.accent.primary),
                    ("subtle", LeafColor.accent.subtle),
                    ("emphasis", LeafColor.accent.emphasis),
                ])
            group(
                "Status",
                swatches: [
                    ("success", LeafColor.status.success),
                    ("warning", LeafColor.status.warning),
                    ("danger", LeafColor.status.danger),
                    ("info", LeafColor.status.info),
                ])
            group(
                "Border",
                swatches: [
                    ("subtle", LeafColor.border.subtle),
                    ("strong", LeafColor.border.strong),
                    ("focus", LeafColor.border.focus),
                ])
        }
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s).font(LeafType.title.large).foregroundStyle(LeafColor.text.primary)
    }

    private func group(_ name: String, swatches: [(String, Color)]) -> some View {
        VStack(alignment: .leading, spacing: LeafSpace.sm) {
            Text(name).leafSectionLabel().foregroundStyle(LeafColor.text.tertiary)
            HStack(spacing: LeafSpace.md) {
                ForEach(swatches, id: \.0) { entry in
                    VStack(alignment: .leading, spacing: LeafSpace.xs) {
                        RoundedRectangle(cornerRadius: LeafRadius.md, style: .continuous)
                            .fill(entry.1)
                            .frame(width: LeafSpace.xxxxl, height: LeafSpace.xxl)
                            .overlay(
                                RoundedRectangle(cornerRadius: LeafRadius.md, style: .continuous)
                                    .strokeBorder(LeafColor.border.subtle, lineWidth: 1)
                            )
                        Text(entry.0)
                            .font(LeafType.mono.small)
                            .foregroundStyle(LeafColor.text.secondary)
                    }
                }
            }
        }
    }
}
#endif
