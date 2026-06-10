//
//  EscalationSheet.swift
//  Leaf
//
//  AI-UI-2 — consent-модалка bodies-эскалации («ИИ просит тела N событий»).
//  Общая для обеих точек входа: Activity multi-select (seed .ids) и Ask Leaf
//  «Dig deeper» (seed .period). Preview = ровно то, что уйдёт (LeafCore
//  EscalationPreviewBuilder); единственный egress — Confirm через
//  AIDetailAnswerer (audit-first → ai_escalation_audit). Ответ — in-place.
//

import LeafCore
import SwiftUI

struct EscalationSheet: View {
  let seed: EscalationSeed
  let onDismiss: () -> Void

  @Environment(WindowState.self) private var windowState

  @State private var reader = EscalationReader()
  @State private var question: String = ""
  @State private var model: SummarizerModel = .haiku

  /// Точное сравнение с opaque-сообщением missingAPIKey — единственный failure
  /// с CTA «Open Settings» (паттерн AskLeafView; AIDetailAnswerer использует
  /// тот же AIWorkAnswerer.message(for:) маппинг).
  private static let missingKeyMessage = AIWorkAnswerer.message(for: .missingAPIKey)

  private static let pickerModels: [SummarizerModel] = [.haiku, .sonnet, .opus]

  var body: some View {
    LeafSheetLayout(title: "Analyze with AI", onDismiss: onDismiss) {
      VStack(alignment: .leading, spacing: LeafSpace.lg) {
        switch reader.loadState {
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
              Task { await reader.load(seed: seed) }
            }
          }
        case .ready:
          if let draft = reader.draft {
            content(draft)
          }
        }
      }
    }
    .frame(minWidth: 480, minHeight: 360)
    .task {
      question = seed.prefillQuestion ?? ""
      await reader.load(seed: seed)
    }
  }

  // MARK: - Content per phase

  @ViewBuilder
  private func content(_ draft: EscalationDraft) -> some View {
    switch draft.phase {
    case .composing, .sending:
      composeView(draft)
    case .answered(let text):
      answeredView(text)
    case .failed(let message):
      failedView(message)
    }
  }

  @ViewBuilder
  private func composeView(_ draft: EscalationDraft) -> some View {
    VStack(alignment: .leading, spacing: LeafSpace.lg) {
      VStack(alignment: .leading, spacing: LeafSpace.xxs) {
        Text(
          "AI asks for the text of \(draft.selectedCount) of \(draft.candidates.count) event\(draft.candidates.count == 1 ? "" : "s")"
        )
        .font(LeafType.body.regular)
        .foregroundStyle(LeafColor.text.primary)
        Text("Bodies leave this Mac only when you confirm. Every send is logged to AI privacy (Settings → Sharing).")
          .font(LeafType.body.small)
          .foregroundStyle(LeafColor.text.tertiary)
      }

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

      Divider()

      TextField("What should the AI do with these events' text?", text: $question, axis: .vertical)
        .textFieldStyle(.plain)
        .font(LeafType.body.regular)
        .lineLimit(1...3)

      HStack(spacing: LeafSpace.md) {
        Picker("Model", selection: $model) {
          ForEach(Self.pickerModels, id: \.self) {
            Text(modelLabel($0)).tag($0)
          }
        }
        .fixedSize()
        Spacer()
        if case .sending = draft.phase {
          HStack(spacing: LeafSpace.sm) {
            ProgressView().controlSize(.small)
            Text("Analyzing…")
              .font(LeafType.body.small)
              .foregroundStyle(LeafColor.text.tertiary)
          }
        } else {
          Button("Send \(draft.selectedCount) \(draft.selectedCount == 1 ? "body" : "bodies")") {
            let q = question
            let m = model
            Task { await reader.confirm(question: q, model: m) }
          }
          .disabled(confirmDisabled(draft))
        }
      }
    }
  }

  private func confirmDisabled(_ draft: EscalationDraft) -> Bool {
    draft.selectedCount == 0
      || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
    .frame(maxHeight: 220)
  }

  @ViewBuilder
  private func candidateRow(_ entry: ActivityFeedEntry, draft: EscalationDraft) -> some View {
    let sendable = draft.isSendable(entry.id)
    HStack(alignment: .top, spacing: LeafSpace.sm) {
      Button {
        reader.toggle(entry.id)
      } label: {
        Image(systemName: draft.isSelected(entry.id) ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(
            draft.isSelected(entry.id) ? LeafColor.text.primary : LeafColor.text.tertiary)
      }
      .buttonStyle(.plain)
      .disabled(!sendable)

      VStack(alignment: .leading, spacing: LeafSpace.xxs) {
        HStack(spacing: LeafSpace.sm) {
          Text(entry.mergedCount > 1 ? "\(entry.primaryText) × \(entry.mergedCount)" : entry.primaryText)
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

  private func answeredView(_ text: String) -> some View {
    VStack(alignment: .leading, spacing: LeafSpace.lg) {
      ScrollView {
        Text(text)
          .font(LeafType.body.regular)
          .foregroundStyle(LeafColor.text.primary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack {
        Spacer()
        Button("Done") { onDismiss() }
      }
    }
  }

  private func failedView(_ message: String) -> some View {
    VStack(alignment: .leading, spacing: LeafSpace.lg) {
      Text(message)
        .font(LeafType.body.regular)
        .foregroundStyle(LeafColor.status.warning)
      HStack(spacing: LeafSpace.md) {
        if message == Self.missingKeyMessage {
          Button("Open Settings") {
            windowState.section = .settings
            onDismiss()
          }
        }
        Button("Try again") { reader.retry() }
        Spacer()
        Button("Cancel") { onDismiss() }
          .buttonStyle(.plain)
          .foregroundStyle(LeafColor.text.tertiary)
      }
    }
  }

  private func modelLabel(_ m: SummarizerModel) -> String {
    switch m {
    case .haiku: "Haiku"
    case .sonnet: "Sonnet"
    case .opus: "Opus"
    default: m.rawValue
    }
  }
}
