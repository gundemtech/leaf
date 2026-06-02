//
//  WaitingForInviteView.swift
//  Leaf
//
//  Phase 5.5.B — onboarding Step 1.5 for the invitee: after sharing the Join code, the user waits for
//  the invite link. Auto-progress on (a) `.onOpenURL` or (b) `applicationDidBecomeActive`
//  clipboard-probe. Manual fallback — "I have the invite link" → opens AcceptInviteSheet.
//
//  Track 2 / D4 — migrated to D1 atoms (LeafType / LeafButton / LeafColor / LeafSpace).
//

import SwiftUI
import LeafCore

struct WaitingForInviteView: View {
    let onManualPaste: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            HStack(spacing: LeafSpace.sm) {
                ProgressView().controlSize(.small)
                Text("Waiting for your team admin…")
                    .font(LeafType.title.small)
                    .foregroundStyle(LeafColor.text.primary)
            }
            Text("Open Leaf after admin sends the invite link — it'll auto-fill from clipboard or open via the link itself.")
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                LeafButton("Back", variant: .ghost, size: .sm, action: onCancel)
                Spacer()
                LeafButton("I have the invite link", variant: .primary, size: .sm, action: onManualPaste)
            }
        }
    }
}
