//
//  InboxBlock.swift
//  Track 8 / Phase 8.2 — Home layout shell. Placeholder body until
//  Phase 8.6 wires `DerivedInsights.inboxItems(filter:query:)`, severity
//  dots, filter chips, searchbar, and aggregation. Phase 8.1 substrate
//  already shipped: `InboxItem`, `InboxKind`, `InboxSeverity`,
//  `InboxFilter`.
//

import LeafCore
import SwiftUI

struct InboxBlock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("INBOX")
                .leafSectionLabel()
                .foregroundStyle(LeafColor.text.tertiary)

            LeafCard(padding: .regular) {
                LeafEmptyState(
                    icon: LeafIcons.brand.leaf,
                    title: "Things needing your attention",
                    description:
                        "Review requests, comments on your work, @-mentions, and open questions will appear here."
                )
            }
        }
    }
}
