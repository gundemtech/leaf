//
//  PrivacySettingsSection.swift
//  Track 2 / D4 — migrated to LeafSection. Phase-1 placeholder: per-app Share
//  Controls land later, so the section just informs the user via a single
//  LeafBanner.info — no empty card chrome.
//

import SwiftUI

struct PrivacySettingsSection: View {
    var body: some View {
        LeafSection(title: "Privacy") {
            LeafBanner(
                tone: .info,
                title: "Per-app Share Controls land in Phase 2",
                description:
                    "Phase 1 ships a hardcoded minimal blocklist (Leaf's own processes + system UI). Editable per-app sharing arrives in the next milestone."
            )
        }
    }
}
