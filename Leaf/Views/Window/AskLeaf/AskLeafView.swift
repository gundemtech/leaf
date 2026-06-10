//
//  AskLeafView.swift
//  Leaf
//
//  AI-UI-1 — вкладка «Ask Leaf»: чат-лента независимых Q&A о своей работе.
//  Каждый вопрос — один BYOK-вызов через AIWorkAnswerer (§8.1 boundary,
//  bodies не уходят). История in-memory (AskLeafTranscript), живёт пока
//  открыто окно.
//

import LeafCore
import SwiftUI

struct AskLeafView: View {
  @Environment(AskLeafReader.self) private var reader
  @Environment(WindowState.self) private var windowState
  /// AI-UI-3 (CTO F1) — NL handoff-intent roster is scoped to the active workspace.
  @Environment(ActiveWorkspaceStore.self) private var activeWorkspaceStore

  @State private var questionText: String = ""
  @State private var period: ReviewActivityInsights.ReviewActivityPeriod = .last7Days
  @State private var model: SummarizerModel = .haiku
  @State private var escalationSeed: EscalationSeed? = nil

  /// AI-UI-3 — NL-intent suggestion → prefilled handoff sheet.
  private struct HandoffSeed: Identifiable {
    let id: String
    let member: TeamMember
    let topic: String
  }
  @State private var handoffSeed: HandoffSeed? = nil

  /// Точное сравнение с opaque-сообщением missingAPIKey — единственный
  /// failure, который получает CTA «Open Settings». Источник строки тот же
  /// модуль (AIWorkAnswerer.message(for:)), текст не дублируем.
  private static let missingKeyMessage = AIWorkAnswerer.message(for: .missingAPIKey)

  private static let suggestions = [
    "What did I work on this week?",
    "Where did I stop yesterday?",
    "Which PRs map to which Linear issues?",
  ]

  /// Только юзер-выбираемые модели: .attestedOpenWeight в пикер не входит.
  private static let pickerModels: [SummarizerModel] = [.haiku, .sonnet, .opus]

  var body: some View {
    VStack(spacing: 0) {
      if reader.transcript.entries.isEmpty {
        emptyState
      } else {
        transcriptList
      }
      Divider()
      inputBar
    }
    .sheet(item: $escalationSeed) { seed in
      EscalationSheet(seed: seed, onDismiss: { escalationSeed = nil })
    }
    // AI-UI-3 — NL-intent suggestion → the same handoff sheet the Team tab
    // uses, prefilled. Slack/Linear reauth closures are no-ops from this entry
    // point — deliberate trade-off (the send itself works; cross-post reauth
    // lives in the Team tab flow).
    .sheet(item: $handoffSeed) { seed in
      SendDirectMessageSheet(
        recipient: seed.member, initialKind: .handoff, initialTopic: seed.topic)
    }
  }

  // MARK: - Transcript

  private var transcriptList: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: LeafSpace.lg) {
          ForEach(reader.transcript.entries) { entry in
            entryView(entry)
              .id(entry.id)
          }
        }
        .padding(LeafSpace.xxl)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .onChange(of: reader.transcript.entries.count) {
        if let last = reader.transcript.entries.last {
          withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
        }
      }
      .onChange(of: reader.transcript.entries.last?.phase) {
        if let last = reader.transcript.entries.last {
          proxy.scrollTo(last.id, anchor: .bottom)
        }
      }
    }
  }

  @ViewBuilder
  private func entryView(_ entry: AskLeafTranscript.Entry) -> some View {
    VStack(alignment: .leading, spacing: LeafSpace.sm) {
      // Question bubble — trailing.
      HStack {
        Spacer(minLength: LeafSpace.xxl)
        VStack(alignment: .trailing, spacing: LeafSpace.xxs) {
          Text(entry.question)
            .font(LeafType.body.regular)
            .foregroundStyle(LeafColor.text.primary)
            .padding(LeafSpace.md)
            .background(LeafColor.surface.inset, in: RoundedRectangle(cornerRadius: LeafRadius.md))
            .textSelection(.enabled)
          Text(periodLabel(entry.period))
            .font(LeafType.body.small)
            .foregroundStyle(LeafColor.text.tertiary)
        }
      }
      // Answer block — leading.
      answerView(entry)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  @ViewBuilder
  private func answerView(_ entry: AskLeafTranscript.Entry) -> some View {
    switch entry.phase {
    case .pending:
      HStack(spacing: LeafSpace.sm) {
        ProgressView().controlSize(.small)
        Text("Thinking…")
          .font(LeafType.body.small)
          .foregroundStyle(LeafColor.text.secondary)
      }
    case .answered(let text):
      VStack(alignment: .leading, spacing: LeafSpace.sm) {
        Text(text)
          .font(LeafType.body.regular)
          .foregroundStyle(LeafColor.text.primary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
        digDeeperButton(entry)
      }
    case .notEnoughData:
      Text("I don't have enough recorded work in that period to answer.")
        .font(LeafType.body.regular)
        .foregroundStyle(LeafColor.text.secondary)
    case .failed(let message):
      VStack(alignment: .leading, spacing: LeafSpace.sm) {
        Text(message)
          .font(LeafType.body.regular)
          .foregroundStyle(LeafColor.status.warning)
        if message == Self.missingKeyMessage {
          Button("Open Settings") {
            windowState.section = .settings
          }
        }
      }
    case .handoffSuggestion(let recipientName, let topic):
      // AI-UI-3 — terminal NL-intent suggestion (no LLM ran).
      VStack(alignment: .leading, spacing: LeafSpace.sm) {
        Text("Looks like you want to hand this off to \(recipientName).")
          .font(LeafType.body.regular)
          .foregroundStyle(LeafColor.text.primary)
        HStack(spacing: LeafSpace.sm) {
          Button("Create handoff for \(recipientName)") {
            if let member = reader.member(named: recipientName) {
              handoffSeed = HandoffSeed(id: "\(entry.id)", member: member, topic: topic)
            }
          }
          Button("Ask anyway") {
            let q = entry.question
            let p = entry.period
            let m = model
            Task { await reader.ask(question: q, period: p, model: m, bypassIntent: true) }
          }
          .buttonStyle(.plain)
          .foregroundStyle(LeafColor.text.secondary)
        }
      }
    }
  }

  /// AI-UI-2 — вход в bodies-эскалацию из ответа: модалка в period-режиме
  /// (кандидаты грузятся сами; consent = активный выбор, ничего не pre-checked).
  private func digDeeperButton(_ entry: AskLeafTranscript.Entry) -> some View {
    Button {
      escalationSeed = .period(entry.period, prefillQuestion: entry.question)
    } label: {
      Text("Dig deeper")
        .font(LeafType.body.small)
        .foregroundStyle(LeafColor.text.secondary)
        .padding(.horizontal, LeafSpace.md)
        .padding(.vertical, LeafSpace.xs)
        .background(LeafColor.surface.inset, in: Capsule())
    }
    .buttonStyle(.plain)
    .help("Send selected event texts to the AI for a detailed answer")
  }

  // MARK: - Empty state

  private var emptyState: some View {
    VStack(spacing: LeafSpace.lg) {
      Spacer()
      LeafEmptyState(
        icon: LeafIcons.brand.leaf,
        title: "Ask Leaf about your work",
        description:
          "Questions are answered from your recorded activity — git, Linear, Slack, AI sessions. Facts only; bodies never leave this Mac."
      )
      VStack(spacing: LeafSpace.xs) {
        ForEach(Self.suggestions, id: \.self) { suggestion in
          Button {
            questionText = suggestion
            send()
          } label: {
            Text(suggestion)
              .font(LeafType.body.small)
              .foregroundStyle(LeafColor.text.secondary)
              .padding(.horizontal, LeafSpace.md)
              .padding(.vertical, LeafSpace.xs)
              .background(LeafColor.surface.inset, in: Capsule())
          }
          .buttonStyle(.plain)
        }
      }
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Input bar

  private var inputBar: some View {
    VStack(alignment: .leading, spacing: LeafSpace.sm) {
      HStack(spacing: LeafSpace.sm) {
        TextField("Ask about your work…", text: $questionText, axis: .vertical)
          .textFieldStyle(.plain)
          .font(LeafType.body.regular)
          .lineLimit(1...4)
          .onSubmit { send() }
        Button("Send") { send() }
          .keyboardShortcut(.return, modifiers: .command)
          .disabled(sendDisabled)
      }
      HStack(spacing: LeafSpace.md) {
        Picker("Period", selection: $period) {
          ForEach(
            [ReviewActivityInsights.ReviewActivityPeriod.today, .yesterday, .last7Days],
            id: \.self
          ) {
            Text(periodLabel($0)).tag($0)
          }
        }
        .fixedSize()
        Picker("Model", selection: $model) {
          ForEach(Self.pickerModels, id: \.self) {
            Text(modelLabel($0)).tag($0)
          }
        }
        .fixedSize()
        Spacer()
        if reader.isAsking {
          Text("Answering…")
            .font(LeafType.body.small)
            .foregroundStyle(LeafColor.text.tertiary)
        }
      }
    }
    .padding(LeafSpace.lg)
  }

  private var sendDisabled: Bool {
    reader.isAsking
      || questionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func send() {
    guard !sendDisabled else { return }
    let q = questionText
    questionText = ""
    let p = period
    let m = model
    let wid = activeWorkspaceStore.activeWorkspaceID
    Task { await reader.ask(question: q, period: p, model: m, activeWorkspaceID: wid) }
  }

  // MARK: - Labels

  private func periodLabel(_ p: ReviewActivityInsights.ReviewActivityPeriod) -> String {
    switch p {
    case .today: "Today"
    case .yesterday: "Yesterday"
    case .last7Days: "Last 7 days"
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
