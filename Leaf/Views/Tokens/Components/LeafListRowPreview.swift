//
//  LeafListRowPreview.swift
//  Track 2 / D1 — TokensPreview entry for Organism O4 LeafListRow.
//

import SwiftUI

#if DEBUG
struct LeafListRowPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("LeafListRow").font(LeafType.title.medium).foregroundStyle(LeafColor.text.primary)

            VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                LeafListRow(primary: "Title only")
                LeafListRow(primary: "Two-line row", secondary: "Secondary text in body.small + tertiary tone")
                LeafListRow(
                    primary: "With leading avatar",
                    secondary: "Online · last seen 5 min ago",
                    leading: { LeafAvatar(initials: "DD", size: .md, statusRing: .success) }
                )
                LeafListRow(
                    primary: "With trailing badge",
                    secondary: "3 unread",
                    trailing: { LeafBadge(count: 3) }
                )
                LeafListRow(
                    primary: "Both slots",
                    secondary: "linear · LEAF-142",
                    leading: { LeafIcon(systemName: "checkmark.circle", size: .md, tint: LeafColor.status.success) },
                    trailing: { LeafBadge(text: "Done", variant: .accent) }
                )
            }

            TokensInlineSpec(
                spec: "LeafListRow · primary + optional secondary · leading + trailing slots · hover bg surface.raised",
                codeSnippet: "LeafListRow(primary: \"Title\", secondary: \"Subtitle\")"
            )
        }
        .padding(LeafSpace.lg)
        .background(LeafColor.surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
    }
}
#endif
