//
//  InboundHandoffContextReader.swift
//  Leaf
//
//  AI-UI-3 — "Context for me" over an inbound handoff DM. Mirrors AskLeafReader:
//  AIWiring defaults, gather own facts off-main (fixed last-7-days window),
//  BYOK-only. Orchestration + audit-first live in LeafCore
//  (InboundHandoffExplainer, SPM-tested); this is glue.
//

import Foundation
import LeafCore
import Observation

@MainActor
@Observable
final class InboundHandoffContextReader {
  enum State: Equatable {
    case idle
    case loading
    case answered(String)
    case error(message: String)
  }

  private(set) var state: State = .idle

  private var explainer: InboundHandoffExplainer?

  private let policy: LLMPolicy
  private let summarizerMoat: AISummarizerMoat
  private let modelGateMoat: ModelGateMoat
  private let promptMoat: HandoffPromptMoat
  private let databaseURL: URL
  private let databaseConfig: DatabaseConfig
  private let databaseEncryption: EncryptionOptions?

  init(
    databaseURL: URL = DatabasePath.defaultURL(),
    databaseConfig: DatabaseConfig = AIWiring.databaseConfig(),
    databaseEncryption: EncryptionOptions? = AIWiring.databaseEncryption(),
    policy: LLMPolicy = AIWiring.policy(),
    summarizerMoat: AISummarizerMoat = AIWiring.summarizerMoat(),
    modelGateMoat: ModelGateMoat = AIWiring.modelGateMoat(),
    promptMoat: HandoffPromptMoat = AIWiring.handoffPromptMoat()
  ) {
    self.policy = policy
    self.summarizerMoat = summarizerMoat
    self.modelGateMoat = modelGateMoat
    self.promptMoat = promptMoat
    self.databaseURL = databaseURL
    self.databaseConfig = databaseConfig
    self.databaseEncryption = databaseEncryption
  }

  func reset() {
    state = .idle
  }

  func explain(handoffText: String, senderName: String, sentAtMs: Int64) async {
    state = .loading
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    let url = databaseURL
    let cfg = databaseConfig
    let enc = databaseEncryption
    let period = DateInterval(start: Date().addingTimeInterval(-7 * 86_400), end: Date())
    let events: [EgressEvent]
    do {
      events = try await Task.detached(priority: .userInitiated) {
        try WorkFactGatherer(dbURL: url, dbConfig: cfg, dbEncryption: enc)
          .gather(period: period, nowMs: nowMs)
      }.value
    } catch {
      state = .error(message: "Couldn't read your activity right now. Try again.")
      return
    }

    let e = ensureExplainer()
    switch await e.explain(
      handoffText: handoffText, senderName: senderName, events: events,
      sentAtMs: sentAtMs, nowMs: nowMs, path: .byok)
    {
    case .text(let text):
      state = .answered(text)
    case .notEnoughData:
      state = .error(
        message: "Not enough of your own activity recorded — read the handoff as is.")
    case .failure(let message):
      state = .error(message: message)
    }
  }

  private func ensureExplainer() -> InboundHandoffExplainer {
    if let e = explainer { return e }
    let audit = DBEscalationAuditSink(
      dbURL: databaseURL, dbConfig: databaseConfig, dbEncryption: databaseEncryption)
    let e = InboundHandoffExplainer(
      policy: policy, summarizer: summarizerMoat.summarizer, modelGate: modelGateMoat.gate,
      prompts: promptMoat.prompts, audit: audit)
    explainer = e
    return e
  }
}
