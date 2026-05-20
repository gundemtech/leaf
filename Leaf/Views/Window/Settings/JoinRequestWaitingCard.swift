//
//  JoinRequestWaitingCard.swift
//  Leaf
//
//  M027 invite-redesign — invitee's post-submit waiting state. 30s poll
//  driven from .task(id: requestID) loop transitions through pending →
//  approved / declined / cancelled / expired. Cancel button while pending.
//

import SwiftUI
import LeafCore

struct JoinRequestWaitingCard: View {
    @Environment(JoinRequestsReader.self) private var reader
    @Environment(\.dismiss) private var dismiss

    /// Poll interval. 30s default per spec §2.3.
    private let pollIntervalSeconds: TimeInterval = 30

    var body: some View {
        LeafSheetLayout(title: "Waiting for admin approval", onDismiss: { dismiss() }) {
            VStack(alignment: .leading, spacing: LeafSpace.lg) {
                contentCard
                Spacer(minLength: 0)
                footer
            }
        }
        .onAppear { startPoll() }
    }

    @ViewBuilder
    private var contentCard: some View {
        LeafCard(variant: .raised, padding: .regular) {
            VStack(alignment: .leading, spacing: LeafSpace.md) {
                statusBlock
            }
        }
    }

    @ViewBuilder
    private var statusBlock: some View {
        switch reader.inviteeState {
        case .idle, .submitting:
            HStack(spacing: LeafSpace.sm) {
                ProgressView()
                Text("Submitting request…")
                    .font(LeafType.body.regular)
                    .foregroundStyle(LeafColor.text.primary)
            }
        case .pending(let row):
            VStack(alignment: .leading, spacing: LeafSpace.sm) {
                HStack(spacing: LeafSpace.sm) {
                    Image(systemName: "hourglass")
                        .foregroundStyle(LeafColor.status.warning)
                    Text("Pending in queue")
                        .font(LeafType.body.regular)
                        .foregroundStyle(LeafColor.text.primary)
                }
                Text("Request sent \(timeAgo(date: row.createdAt))")
                    .font(LeafType.caption)
                    .foregroundStyle(LeafColor.text.tertiary)
                Text("You'll get a notification when the admin approves your request.")
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.secondary)
            }
        case .approved(let row):
            VStack(alignment: .leading, spacing: LeafSpace.sm) {
                HStack(spacing: LeafSpace.sm) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(LeafColor.status.success)
                    Text("Request approved")
                        .font(LeafType.body.regular)
                        .foregroundStyle(LeafColor.text.primary)
                }
                Text("Finalizing join…")
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.secondary)
                Text("Workspace \(row.workspaceID.prefix(8))…")
                    .font(LeafType.caption)
                    .foregroundStyle(LeafColor.text.tertiary)
            }
        case .declined:
            VStack(alignment: .leading, spacing: LeafSpace.sm) {
                HStack(spacing: LeafSpace.sm) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(LeafColor.status.danger)
                    Text("Request declined")
                        .font(LeafType.body.regular)
                        .foregroundStyle(LeafColor.text.primary)
                }
                Text("The admin chose not to admit you to this workspace.")
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.secondary)
            }
        case .cancelled:
            HStack(spacing: LeafSpace.sm) {
                Image(systemName: "minus.circle")
                    .foregroundStyle(LeafColor.text.tertiary)
                Text("Request cancelled")
                    .font(LeafType.body.regular)
                    .foregroundStyle(LeafColor.text.primary)
            }
        case .expired:
            VStack(alignment: .leading, spacing: LeafSpace.sm) {
                HStack(spacing: LeafSpace.sm) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .foregroundStyle(LeafColor.status.warning)
                    Text("Request expired")
                        .font(LeafType.body.regular)
                        .foregroundStyle(LeafColor.text.primary)
                }
                Text("The invite TTL elapsed before the admin reviewed your request.")
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.secondary)
            }
        case .error(let message):
            LeafBanner(tone: .danger, title: message, description: nil)
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            switch reader.inviteeState {
            case .pending(let row):
                LeafButton("Cancel request", variant: .secondary, size: .md) {
                    reader.cancelOwn(requestID: row.requestID)
                }
                Spacer()
                LeafButton("Done", variant: .primary, size: .md) { dismiss() }
            case .approved, .declined, .cancelled, .expired, .error:
                Spacer()
                LeafButton("Done", variant: .primary, size: .md) {
                    reader.resetInviteeState()
                    dismiss()
                }
            case .idle, .submitting:
                Spacer()
                LeafButton("Cancel", variant: .secondary, size: .md) { dismiss() }
            }
        }
    }

    private func startPoll() {
        // .task(id:) with periodic awakening — keeps polling alive only while
        // the card is visible. Stop polling once a terminal state is reached.
        Task { @MainActor in
            while !Task.isCancelled {
                if case .pending(let row) = reader.inviteeState {
                    reader.pollOwn(requestID: row.requestID)
                }
                try? await Task.sleep(nanoseconds: UInt64(pollIntervalSeconds) * 1_000_000_000)
                if case .approved = reader.inviteeState { break }
                if case .declined = reader.inviteeState { break }
                if case .cancelled = reader.inviteeState { break }
                if case .expired = reader.inviteeState { break }
            }
        }
    }

    private func timeAgo(date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }
}
