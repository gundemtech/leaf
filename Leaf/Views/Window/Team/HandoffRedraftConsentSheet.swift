//
//  HandoffRedraftConsentSheet.swift
//  Leaf
//
//  AI-UI-3 — escalation-in-draft consent step. Visual mirror of EscalationSheet:
//  candidates for the draft period (unchecked — consent is an active choice),
//  exact capped body under disclosure, dropped rows marked "never sent".
//  [Redraft with K bodies] → HandoffDraftReader.redraft (audit-first M031 inside
//  HandoffDrafter) → the parent sheet's .onChange(handoffReader.state) fills the
//  editable body; this sheet dismisses itself when the redraft lands.
//

import LeafCore
import SwiftUI

struct HandoffRedraftConsentSheet: View {
  let recipientName: String
  let topic: String
  let period: ReviewActivityInsights.ReviewActivityPeriod

  @Environment(HandoffDraftReader.self) private var handoffReader
  @Environment(\.dismiss) private var dismiss

  enum LoadState {
    case loading
    case ready
    case failed(String)
  }

  @State private var loadState: LoadState = .loading
  @State private var draft: EscalationDraft?
  @State private var isRedrafting = false
  /// CTO F4 — redraft failure must be visible IN this sheet (the parent's
  /// error row is underneath the presented sheet).
  @State private var redraftError: String? = nil

  private let databaseURL = DatabasePath.defaultURL()
  private let databaseConfig = AIWiring.databaseConfig()
  private let databaseEncryption = AIWiring.databaseEncryption()
  private let policy = AIWiring.policy()

  var body: some View {
    LeafSheetLayout(title: "Add details to the draft", onDismiss: { dismiss() }) {
      VStack(alignment: .leading, spacing: LeafSpace.lg) {
        Text(
          "Selected event texts will be sent to your AI to make the draft concrete. "
            + "Nothing is selected until you check it; greyed rows can never be sent."
        )
        .font(LeafType.body.small)
        .foregroundStyle(LeafColor.text.tertiary)
        content
        Spacer(minLength: 0)
        footer
      }
    }
    .frame(minWidth: 480, minHeight: 360)
    .task { await load() }
    // Redraft landed (the parent's onChange already filled the body) → close.
    .onChange(of: handoffReader.state) { _, newState in
      guard isRedrafting else { return }
      if case .drafted = newState { dismiss() }
      if case .error(let message) = newState {
        isRedrafting = false
        redraftError = message  // CTO F4 — surface in THIS sheet
      }
    }
  }

  @ViewBuilder
  private var content: some View {
    switch loadState {
    case .loading:
      HStack(spacing: LeafSpace.sm) {
        ProgressView().controlSize(.small)
        Text("Reading events…")
          .font(LeafType.body.small)
          .foregroundStyle(LeafColor.text.tertiary)
      }
    case .failed(let msg):
      VStack(alignment: .leading, spacing: LeafSpace.sm) {
        Text(msg)
          .font(LeafType.body.regular)
          .foregroundStyle(LeafColor.status.warning)
        Button("Try again") {
          Task { await load() }
        }
      }
    case .ready:
      if let draft {
        if draft.candidates.isEmpty {
          Text("No events in this period.")
            .font(LeafType.body.small)
            .foregroundStyle(LeafColor.text.tertiary)
        } else {
          if draft.sendableCount == 0 {
            Text("These events have no text that can be sent.")
              .font(LeafType.body.small)
              .foregroundStyle(LeafColor.text.secondary)
          }
          candidateList(draft)
        }
      }
    }
  }

  private func candidateList(_ draft: EscalationDraft) -> some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(draft.candidates) { entry in
          candidateRow(entry, draft: draft)
            .padding(.vertical, LeafSpace.xs)
          if entry.id != draft.candidates.last?.id {
            LeafDivider(style: .soft)
          }
        }
      }
    }
    .frame(maxHeight: 240)
  }

  @ViewBuilder
  private func candidateRow(_ entry: ActivityFeedEntry, draft: EscalationDraft) -> some View {
    let sendable = draft.isSendable(entry.id)
    HStack(alignment: .top, spacing: LeafSpace.sm) {
      Button {
        self.draft?.toggle(entry.id)
      } label: {
        Image(systemName: draft.isSelected(entry.id) ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(
            draft.isSelected(entry.id) ? LeafColor.text.primary : LeafColor.text.tertiary)
      }
      .buttonStyle(.plain)
      .disabled(!sendable || isRedrafting)

      VStack(alignment: .leading, spacing: LeafSpace.xxs) {
        HStack(spacing: LeafSpace.sm) {
          Text(
            entry.mergedCount > 1 ? "\(entry.primaryText) × \(entry.mergedCount)" : entry.primaryText
          )
          .font(LeafType.body.regular)
          .foregroundStyle(sendable ? LeafColor.text.primary : LeafColor.text.tertiary)
          .lineLimit(1)
          if !sendable {
            Text("never sent")
              .font(LeafType.body.small)
              .foregroundStyle(LeafColor.text.tertiary)
              .padding(.horizontal, LeafSpace.xs)
              .background(LeafColor.surface.inset, in: Capsule())
          }
          Spacer()
          Text(entry.timestamp, style: .time)
            .font(LeafType.body.small)
            .foregroundStyle(LeafColor.text.tertiary)
        }
        if let body = draft.preview[entry.id] {
          DisclosureGroup("Exactly what will be sent") {
            VStack(alignment: .leading, spacing: LeafSpace.xxs) {
              Text(body.authoredByViewer ? "Written by you" : "Written by someone else")
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.tertiary)
              Text(body.text)
                .font(LeafType.mono.small)
                .foregroundStyle(LeafColor.text.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(LeafSpace.sm)
            .background(LeafColor.surface.inset, in: RoundedRectangle(cornerRadius: LeafRadius.sm))
          }
          .font(LeafType.body.small)
        }
      }
    }
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: LeafSpace.xs) {
      if let redraftError {
        Text(redraftError)
          .font(LeafType.body.small)
          .foregroundStyle(LeafColor.status.warning)
      }
      HStack {
        Button("Cancel") { dismiss() }
          .buttonStyle(.plain)
          .foregroundStyle(LeafColor.text.tertiary)
        Spacer()
        if isRedrafting {
          HStack(spacing: LeafSpace.sm) {
            ProgressView().controlSize(.small)
            Text("Redrafting…")
              .font(LeafType.body.small)
              .foregroundStyle(LeafColor.text.tertiary)
          }
        } else {
          let count = draft?.selectedCount ?? 0
          Button("Redraft with \(count) \(count == 1 ? "body" : "bodies")") {
            Task { await redraft() }
          }
          .disabled(count == 0)
        }
      }
    }
  }

  /// Same load shape as EscalationReader.load(seed: .period) — candidates,
  /// keyed bodies, exact preview. Unchecked: consent is an active choice.
  private func load() async {
    loadState = .loading
    let url = databaseURL
    let cfg = databaseConfig
    let enc = databaseEncryption
    let pol = policy
    let interval = period.interval()
    do {
      let candidates = try await Task.detached(priority: .userInitiated) {
        try ActivityFeedQuery(dbURL: url, dbConfig: cfg, dbEncryption: enc)
          .fetch(period: interval)
      }.value
      let ids = candidates.map(\.id)
      let pairs = try await Task.detached(priority: .userInitiated) {
        try WorkFactGatherer(dbURL: url, dbConfig: cfg, dbEncryption: enc)
          .gatherSelectedBodiesKeyed(eventIDs: ids)
      }.value
      draft = EscalationDraft(
        candidates: candidates,
        preview: EscalationPreviewBuilder.preview(keyed: pairs, policy: pol),
        preselected: [])
      loadState = .ready
    } catch {
      loadState = .failed("Couldn't read those events right now. Try again.")
    }
  }

  private func redraft() async {
    guard let d = draft, d.selectedCount > 0 else { return }
    redraftError = nil
    isRedrafting = true
    await handoffReader.redraft(
      recipientName: recipientName, topic: topic, period: period.interval(),
      selectedEventIDs: Array(d.selected))
    // Success path dismisses via onChange(.drafted); if state settled before
    // the observer fired, mirror it here.
    if case .drafted = handoffReader.state { dismiss() }
    if case .error(let message) = handoffReader.state {
      isRedrafting = false
      redraftError = message
    }
  }
}
