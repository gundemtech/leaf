//
//  LeafAvatarPreview.swift
//  Track 2 / D1 — TokensPreview entry for Molecule M8 LeafAvatar.
//

import SwiftUI

#if DEBUG
struct LeafAvatarPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("LeafAvatar").font(LeafType.title.medium).foregroundStyle(LeafColor.text.primary)

            HStack(spacing: LeafSpace.lg) {
                LeafAvatar(initials: "DD", size: .sm)
                LeafAvatar(initials: "DD", size: .md)
                LeafAvatar(initials: "DD", size: .lg)
            }

            HStack(spacing: LeafSpace.lg) {
                LeafAvatar(initials: "AC", size: .md, statusRing: .accent)
                LeafAvatar(initials: "OK", size: .md, statusRing: .success)
                LeafAvatar(initials: "WA", size: .md, statusRing: .warning)
                LeafAvatar(initials: "ER", size: .md, statusRing: .danger)
                LeafAvatar(initials: "??", size: .md, statusRing: .muted)
            }

            TokensInlineSpec(
                spec: "LeafAvatar · sm(24)/md(36)/lg(56) · initials/image · status ring tinted via LeafDotTone",
                codeSnippet: "LeafAvatar(initials: \"DD\", size: .md, statusRing: .accent)"
            )
        }
        .padding(LeafSpace.lg)
        .background(LeafColor.surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
    }
}
#endif
