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
    case error(AIFailure)
  }

  private(set) var state: State = .idle

  private let policy: LLMPolicy
  private let router: AIBackendRouter
  private let modelGateMoat: ModelGateMoat
  private let promptMoat: HandoffPromptMoat
  private let databaseURL: URL
  private let databaseConfig: DatabaseConfig
  private let databaseEncryption: EncryptionOptions?

  init(
    router: AIBackendRouter,
    databaseURL: URL = DatabasePath.defaultURL(),
    databaseConfig: DatabaseConfig = AIWiring.databaseConfig(),
    databaseEncryption: EncryptionOptions? = AIWiring.databaseEncryption(),
    policy: LLMPolicy = AIWiring.policy(),
    modelGateMoat: ModelGateMoat = AIWiring.modelGateMoat(),
    promptMoat: HandoffPromptMoat = AIWiring.handoffPromptMoat()
  ) {
    self.policy = policy
    self.router = router
    self.modelGateMoat = modelGateMoat
    self.promptMoat = promptMoat
    self.databaseURL = databaseURL
    self.databaseConfig = databaseConfig
    self.databaseEncryption = databaseEncryption
  }

  func reset() {
    state = .idle
  }

  /// No sender name (review HIGH-1): the display name is sender-supplied
  /// plaintext and must never reach the instruction slot.
  func explain(handoffText: String, sentAtMs: Int64) async {
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
      state = .error(
        AIFailure(
          kind: .localRead, message: "Couldn't read your activity right now. Try again."))
      return
    }

    // AI-UI-4 — resolve the backend per explain (BYOK valve).
    let r = router.resolve()
    let e = makeExplainer(summarizer: r.summarizer)
    switch await e.explain(
      handoffText: handoffText, events: events,
      sentAtMs: sentAtMs, nowMs: nowMs, path: r.path)
    {
    case .text(let text):
      state = .answered(text)
    case .notEnoughData:
      state = .error(
        AIFailure(
          kind: .localRead,
          message: "Not enough of your own activity recorded — read the handoff as is."))
    case .failure(let failure):
      state = .error(failure)
    }
  }

  private func makeExplainer(summarizer: any Summarizer) -> InboundHandoffExplainer {
    let audit = DBEscalationAuditSink(
      dbURL: databaseURL, dbConfig: databaseConfig, dbEncryption: databaseEncryption)
    return InboundHandoffExplainer(
      policy: policy, summarizer: summarizer, modelGate: modelGateMoat.gate,
      prompts: promptMoat.prompts, audit: audit)
  }
}
