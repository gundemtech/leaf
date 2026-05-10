//
//  PrivacySettingsSection.swift
//  Track 2 / D4 — migrated to LeafSection. Section description carries copy;
//  no LeafCard chrome (informational text only).
//

import SwiftUI

struct PrivacySettingsSection: View {
    var body: some View {
        LeafSection(
            title: "Privacy",
            description: "Phase 1 uses a hardcoded minimal blocklist (Leaf's own processes + system UI). Editable per-app Share Controls land in Phase 2."
        ) {
            EmptyView()
        }
    }
}
