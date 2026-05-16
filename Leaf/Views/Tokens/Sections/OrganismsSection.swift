//
//  OrganismsSection.swift
//  Track 2 / D1 — Stub. Filled by Tasks 25–34.
//

import SwiftUI

#if DEBUG
struct OrganismsSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.xl) {
            Text("Organisms").font(LeafType.title.large).foregroundStyle(LeafColor.text.primary)
            LeafCardPreview()
            LeafSectionPreview()
            LeafNavRowPreview()
            LeafListRowPreview()
            LeafStatusPillPreview()
            LeafBannerPreview()
            LeafEmptyStatePreview()
            LeafToolbarPreview()
            LeafTabPreview()
            LeafProgressPreview()
            LeafWorkspaceSwitcherPreview()
            LeafLinkedEventCardPreview()
            LeafMessageCardPreview()
            LeafFeedRowPreview()
        }
    }
}
#endif
