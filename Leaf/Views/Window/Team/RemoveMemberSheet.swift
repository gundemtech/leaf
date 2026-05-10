//
//  RemoveMemberSheet.swift
//  Leaf
//
//  Phase 5.3.E — admin remove-member confirmation sheet. State machine routed
//  through MemberRemovalReader. Mirror GenerateInviteSheet (5.2.D) shape:
//  header / state-routed content ViewBuilder / footer.
//

import SwiftUI
import LeafCore

struct RemoveMemberSheet: View {
    @Environment(MemberRemovalReader.self) private var reader
    @Environment(OrgReader.self) private var orgReader
    @Environment(\.dismiss) private var dismiss

    let memberID: String
    let displayName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            content
            Spacer(minLength: 0)
            footer
        }
        .padding(28)
        .frame(width: 520, height: 380)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("REMOVE MEMBER").leafLabelStyle()
            Text("Remove \(displayName) from the team?")
                .font(.leafHeadline).foregroundStyle(.leafInk)
        }
    }

    // MARK: - Content (state-routed)

    @ViewBuilder
    private var content: some View {
        switch reader.state {
        case .idle:
            confirmCard
        case .removing:
            confirmCard
            HStack { Spacer(); ProgressView("Rotating team key…"); Spacer() }
        case .success(let outcome, let dn):
            successCard(displayName: dn, outcome: outcome)
        case .error(let message):
            errorCard(message: message)
        }
    }

    private var confirmCard: some View {
        GlassCard(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                Text("This rotates the team key. \(displayName) won't be able to send presence under the previous key. They'll see a 'You've been removed' message in their app on next sync.")
                    .font(.leafBody)
                    .foregroundStyle(.leafInk)
                    .lineSpacing(3)
            }
        }
    }

    private func successCard(displayName: String, outcome: RotationOutcome) -> some View {
        GlassCard(padding: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Removed \(displayName)", image: LeafIcons.status.successFill)
                    .font(.leafHeadline).foregroundStyle(.green)
                if outcome.pendingCount > 0 {
                    Text("\(outcome.postedCount) of \(outcome.totalCount) peers notified. \(outcome.pendingCount) will sync when online.")
                        .font(.leafBody).foregroundStyle(.leafInk.opacity(0.85))
                } else if outcome.postedCount > 0 {
                    Text("All \(outcome.postedCount) peer\(outcome.postedCount == 1 ? "" : "s") notified.")
                        .font(.leafBody).foregroundStyle(.leafInk.opacity(0.85))
                } else {
                    Text("Local rotation done. No remaining peers to notify.")
                        .font(.leafBody).foregroundStyle(.leafInk.opacity(0.85))
                }
            }
        }
    }

    private func errorCard(message: String) -> some View {
        GlassCard(padding: 24) {
            VStack(alignment: .leading, spacing: 16) {
                Label("Couldn't remove member", image: LeafIcons.status.warningFill)
                    .font(.leafBody.weight(.semibold))
                    .foregroundStyle(.red)
                Text(message)
                    .font(.leafBody)
                    .foregroundStyle(.leafInk)
                    .lineSpacing(3)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Cancel") {
                reader.dismiss()
                dismiss()
            }
            .buttonStyle(.bordered)

            Spacer()

            switch reader.state {
            case .idle:
                Button("Remove") {
                    reader.removeMember(memberID: memberID, displayName: displayName)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            case .removing:
                Button("Remove") { }
                    .disabled(true)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            case .success:
                Button("Done") {
                    orgReader.refresh()
                    reader.dismiss()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            case .error:
                Button("Close") {
                    reader.dismiss()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
