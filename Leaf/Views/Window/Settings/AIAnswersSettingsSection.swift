//
//  AIAnswersSettingsSection.swift
//  Leaf
//
//  AI-UI-1 — Settings → Data → AI Answers. Пишет через FileAnthropicKeyStore —
//  ОДИН источник ключа для in-app Ask Leaf И MCP ask_about_my_work (MCPServer
//  Keychain читать не может — P1-решение). Ключ never displayed / never logged:
//  loadKey() используется только как boolean-присутствие.
//
//  AI-UI-4 — keyless больше не «выключено»: in-app поверхности едут на
//  командном пуле, ключ = optional override. Все state→copy строки — из
//  AIAnswersSettingsPresentation (LeafCore, SPM-tested).
//

import LeafCore
import SwiftUI

struct AIAnswersSettingsSection: View {
  @State private var keyInput: String = ""
  @State private var hasKey: Bool = false
  @State private var feedback: Feedback? = nil

  private enum Feedback: Equatable {
    case saved
    case removed
    case warningFormat  // suspicious prefix — second Save stores anyway
    case error(String)
  }

  private let store = FileAnthropicKeyStore()

  private var presentation: AIAnswersSettingsPresentation.Model {
    AIAnswersSettingsPresentation.model(hasKey: hasKey)
  }

  var body: some View {
    LeafSection(
      title: "AI Answers",
      description: presentation.sectionDescription
    ) {
      VStack(alignment: .leading, spacing: LeafSpace.sm) {
        statusRow
        HStack(spacing: LeafSpace.sm) {
          SecureField("sk-ant-…", text: $keyInput)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 360)
          Button("Save") { save() }
            .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          if hasKey {
            Button("Remove key", role: .destructive) { remove() }
          }
        }
        feedbackRow
      }
    }
    .onAppear { refreshHasKey() }
  }

  // MARK: - Rows

  private var statusRow: some View {
    HStack(spacing: LeafSpace.sm) {
      LeafDot(tone: presentation.statusIsActive ? .success : .muted, size: .sm)
      Text(presentation.statusLabel)
        .font(LeafType.body.small)
        .foregroundStyle(LeafColor.text.secondary)
    }
  }

  @ViewBuilder
  private var feedbackRow: some View {
    if let feedback {
      Text(feedbackText(feedback))
        .font(LeafType.body.small)
        .foregroundStyle(
          feedback == .warningFormat
            ? LeafColor.status.warning : LeafColor.text.secondary)
    }
  }

  private func feedbackText(_ f: Feedback) -> String {
    switch f {
    case .saved:
      presentation.savedFeedback
    case .removed:
      presentation.removedFeedback
    case .warningFormat:
      "Doesn't look like an Anthropic key (sk-ant-…). Press Save again to store anyway."
    case .error(let message):
      message
    }
  }

  // MARK: - Actions

  private func save() {
    switch AnthropicKeyValidator.validate(keyInput) {
    case .emptyInput:
      return
    case .ok(let key):
      store(key)
    case .suspiciousFormat(let key):
      // First press warns; second press (warning visible) stores anyway.
      if feedback == .warningFormat {
        store(key)
      } else {
        feedback = .warningFormat
      }
    }
  }

  private func store(_ key: String) {
    do {
      try store.storeKey(key)
      keyInput = ""
      feedback = .saved
      refreshHasKey()
    } catch {
      feedback = .error("Couldn't write the key file. Check disk permissions.")
    }
  }

  private func remove() {
    do {
      try store.deleteKey()
      feedback = .removed
      refreshHasKey()
    } catch {
      feedback = .error("Couldn't remove the key file. Check disk permissions.")
    }
  }

  private func refreshHasKey() {
    hasKey = ((try? store.loadKey()) ?? nil) != nil
  }
}
