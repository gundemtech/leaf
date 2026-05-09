//
//  MoleculesSection.swift
//  Track 2 / D1 — Filled by Tasks 15–24.
//

import SwiftUI

#if DEBUG
struct MoleculesSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.xl) {
            Text("Molecules").font(LeafType.title.large).foregroundStyle(LeafColor.text.primary)
            LeafButtonPreview()
            LeafIconButtonPreview()
            LeafPillPreview()
            LeafBadgePreview()
            LeafTogglePreview()
            LeafInputPreview()
            LeafSelectPreview()
            LeafAvatarPreview()
            LeafIconLabelPreview()
            LeafKeyboardShortcutPreview()
        }
    }
}
#endif
