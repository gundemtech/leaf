//
//  JoinRequestWaitingCard.swift
//  Leaf
//
//  M027 invite-redesign — invitee's post-submit waiting state. 30s poll
//  driven from .task(id: requestID) loop transitions through pending →
//  approved / declined / cancelled / expired. Cancel button while pending.
//

import LeafCore
import SwiftUI

struct JoinRequestWaitingCard: View {
  @Environment(JoinRequestsReader.self) private var reader
  /// Surfaces the freshly-joined workspace by refreshing + switching active
  /// once `.joined` lands — the local materialisation already INSERTed the
  /// rows, but the reader's in-memory `state` needs a `refresh()` to pick
  /// them up; setting active flips the sidebar focus so the user lands in
  /// the new workspace's Team view on dismiss.
  @Environment(WorkspaceReader.self) private var workspaceReader
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
    case .approved:
      VStack(alignment: .leading, spacing: LeafSpace.sm) {
        HStack(spacing: LeafSpace.sm) {
          ProgressView()
          Text("Request approved — joining…")
            .font(LeafType.body.regular)
            .foregroundStyle(LeafColor.text.primary)
        }
        Text("Decrypting team key and materialising workspace locally.")
          .font(LeafType.body.small)
          .foregroundStyle(LeafColor.text.secondary)
      }
    case .joined(_, let workspaceName):
      VStack(alignment: .leading, spacing: LeafSpace.sm) {
        HStack(spacing: LeafSpace.sm) {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(LeafColor.status.success)
          Text("Joined \(workspaceName.isEmpty ? "workspace" : "\u{201C}\(workspaceName)\u{201D}")")
            .font(LeafType.body.regular)
            .foregroundStyle(LeafColor.text.primary)
        }
        Text("You're in. Welcome to the team.")
          .font(LeafType.body.small)
          .foregroundStyle(LeafColor.text.secondary)
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
      case .approved:
        // Materialisation in flight — no user action available; Done waits
        // for the .joined transition or .error.
        Spacer()
        LeafButton("Done", variant: .primary, size: .md, action: {})
          .disabled(true)
      case .joined(let workspaceID, _):
        Spacer()
        LeafButton("Open workspace", variant: .primary, size: .md) {
          workspaceReader.switchActive(to: workspaceID)
          reader.resetInviteeState()
          dismiss()
        }
      case .declined, .cancelled, .expired, .error:
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
        // .approved is transient (materialisation in flight) — keep
        // looping so we re-poll if the server confirms again; the
        // dedup set in JoinRequestsReader prevents double-materialise.
        if case .joined = reader.inviteeState { break }
        if case .declined = reader.inviteeState { break }
        if case .cancelled = reader.inviteeState { break }
        if case .expired = reader.inviteeState { break }
        if case .error = reader.inviteeState { break }
      }
    }
  }

  private func timeAgo(date: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .full
    return f.localizedString(for: date, relativeTo: Date())
  }
}
