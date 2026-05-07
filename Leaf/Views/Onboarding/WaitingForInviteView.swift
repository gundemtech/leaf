//
//  WaitingForInviteView.swift
//  Leaf
//
//  Phase 5.5.B — onboarding Step 1.5 для invitee: после share Join code'а юзер ждёт
//  invite link. Auto-progress на (a) `.onOpenURL` (LeafApp dispatches на handler) либо
//  (b) `applicationDidBecomeActive` clipboard-probe (handler.probeClipboard returns inviteURL).
//  Manual fallback — "I have the invite link" → opens AcceptInviteSheet.
//

import SwiftUI
import LeafCore

struct WaitingForInviteView: View {
    let onManualPaste: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for your team admin…")
                    .font(.subheadline.weight(.semibold))
            }
            Text("Open Leaf after admin sends the invite link — it'll auto-fill from clipboard or open via the link itself.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Back") { onCancel() }
                    .buttonStyle(.link)
                    .font(.caption)
                Spacer()
                Button("I have the invite link") { onManualPaste() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
