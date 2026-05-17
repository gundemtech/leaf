//
//  RemoveMemberSheet.swift
//  Leaf
//
//  Phase 5.3.E — admin remove-member confirmation sheet. State machine routed
//  through MemberRemovalReader.
//
//  Track 2 / D4 — migrated to LeafSheetLayout + LeafCard.raised + LeafBanner.
//

import LeafCore
import SwiftUI

struct RemoveMemberSheet: View {
    @Environment(MemberRemovalReader.self) private var reader
    @Environment(OrgReader.self) private var orgReader
    @Environment(\.dismiss) private var dismiss

    let memberID: String
    let displayName: String

    var body: some View {
        LeafSheetLayout(title: "Remove member", onDismiss: dismissAndDiscard) {
            VStack(alignment: .leading, spacing: LeafSpace.xl) {
                primaryQuestion
                content
                Spacer(minLength: 0)
                footer
            }
        }
    }

    private var primaryQuestion: some View {
        Text("Remove \(displayName) from the team?")
            .font(LeafType.title.medium)
            .foregroundStyle(LeafColor.text.primary)
    }

    @ViewBuilder
    private var content: some View {
        switch reader.state {
        case .idle:
            confirmCard
        case .removing:
            confirmCard
            HStack {
                Spacer()
                ProgressView("Rotating team key…")
                Spacer()
            }
        case .success(let outcome, let dn):
            successCard(displayName: dn, outcome: outcome)
        case .error(let message):
            LeafBanner(tone: .danger, title: "Couldn't remove member", description: message)
        }
    }

    private var confirmCard: some View {
        LeafCard(variant: .raised, padding: .regular) {
            Text(
                "This rotates the team key. \(displayName) won't be able to send presence under the previous key. They'll see a 'You've been removed' message in their app on next sync."
            )
            .font(LeafType.body.regular)
            .foregroundStyle(LeafColor.text.primary)
        }
    }

    private func successCard(displayName: String, outcome: RotationOutcome) -> some View {
        LeafCard(variant: .raised, padding: .generous) {
            VStack(alignment: .leading, spacing: LeafSpace.md) {
                LeafIconLabel(
                    icon: .asset(LeafIcons.status.successFill),
                    title: "Removed \(displayName)",
                    iconTint: LeafColor.status.success,
                    titleStyle: LeafType.title.small
                )
                Text(successSummary(outcome: outcome))
                    .font(LeafType.body.regular)
                    .foregroundStyle(LeafColor.text.primary)
            }
        }
    }

    private func successSummary(outcome: RotationOutcome) -> String {
        if outcome.pendingCount > 0 {
            return
                "\(outcome.postedCount) of \(outcome.totalCount) peers notified. \(outcome.pendingCount) will sync when online."
        } else if outcome.postedCount > 0 {
            return "All \(outcome.postedCount) peer\(outcome.postedCount == 1 ? "" : "s") notified."
        } else {
            return "Local rotation done. No remaining peers to notify."
        }
    }

    private var footer: some View {
        HStack {
            LeafButton("Cancel", variant: .secondary, size: .md, action: dismissAndDiscard)
            Spacer()
            switch reader.state {
            case .idle:
                LeafButton(
                    "Remove",
                    variant: .destructive,
                    size: .md,
                    action: { reader.removeMember(memberID: memberID, displayName: displayName) }
                )
            case .removing:
                LeafButton("Remove", variant: .destructive, size: .md, isLoading: true, action: {})
                    .disabled(true)
            case .success:
                LeafButton(
                    "Done",
                    variant: .primary,
                    size: .md,
                    action: {
                        orgReader.refresh()
                        reader.dismiss()
                        dismiss()
                    }
                )
            case .error:
                LeafButton("Close", variant: .primary, size: .md, action: dismissAndDiscard)
            }
        }
    }

    private func dismissAndDiscard() {
        reader.dismiss()
        dismiss()
    }
}
