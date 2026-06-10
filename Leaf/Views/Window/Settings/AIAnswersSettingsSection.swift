//
//  AIAnswersSettingsSection.swift
//  Leaf
//
//  AI-UI-1 — Settings → Data → AI Answers. Первый UI для BYOK Anthropic-ключа
//  (до этого ключ клали в файл руками). Пишет через FileAnthropicKeyStore —
//  ОДИН источник ключа для in-app Ask Leaf И MCP ask_about_my_work (MCPServer
//  Keychain читать не может — P1-решение). Ключ never displayed / never logged:
//  loadKey() используется только как boolean-присутствие.
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

  var body: some View {
    LeafSection(
      title: "AI Answers",
      description:
        "Bring your own Anthropic API key to enable AI answers — in the Ask Leaf tab and the MCP ask_about_my_work tool. The key is stored locally in a permission-restricted file and never leaves this Mac except to call Anthropic."
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
      LeafDot(tone: hasKey ? .success : .muted, size: .sm)
      Text(hasKey ? "Key configured" : "No key configured")
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
      "Key saved. AI answers are live in Ask Leaf and MCP."
    case .removed:
      "Key removed. AI answers are disabled until you add a key."
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
