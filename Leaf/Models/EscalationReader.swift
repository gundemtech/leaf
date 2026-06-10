//
//  EscalationReader.swift
//  Leaf
//
//  AI-UI-2 — @Observable клей escalation-модалки. Зеркало AskLeafReader:
//  AIWiring-дефолты, lazy AIDetailAnswerer bootstrap, fetch off-main, BYOK-only.
//  Логика выбора/фаз — LeafCore (EscalationDraft, SPM-tested); audit-first и
//  bucket-1 — внутри AIDetailAnswerer/LLMPolicy (неизменны, паритет с MCP-путём).
//

import Foundation
import LeafCore
import Observation

/// Seed модалки: явные события из Activity или период из Ask Leaf.
enum EscalationSeed: Identifiable {
  case ids([ActivityFeedEntry])
  case period(ReviewActivityInsights.ReviewActivityPeriod, prefillQuestion: String?)

  var id: String {
    switch self {
    case .ids(let entries):
      "ids:\(entries.map { String($0.id) }.joined(separator: ","))"
    case .period(let p, _):
      "period:\(p)"
    }
  }

  var prefillQuestion: String? {
    if case .period(_, let q) = self { return q }
    return nil
  }
}

@MainActor
@Observable
final class EscalationReader {
  /// Паритет с EscalateToAITool.maxAnswerTokens (MCP-путь).
  static let maxAnswerTokens = 1024

  enum LoadState {
    case loading
    case ready
    case failed(String)
  }

  private(set) var loadState: LoadState = .loading
  private(set) var draft: EscalationDraft?

  private var keyed: [(id: Int64, event: EgressEvent)] = []
  private var answerer: AIDetailAnswerer?

  private let policy: LLMPolicy
  private let summarizerMoat: AISummarizerMoat
  private let modelGateMoat: ModelGateMoat
  private let databaseURL: URL
  private let databaseConfig: DatabaseConfig
  private let databaseEncryption: EncryptionOptions?

  init(
    databaseURL: URL = DatabasePath.defaultURL(),
    databaseConfig: DatabaseConfig = AIWiring.databaseConfig(),
    databaseEncryption: EncryptionOptions? = AIWiring.databaseEncryption(),
    policy: LLMPolicy = AIWiring.policy(),
    summarizerMoat: AISummarizerMoat = AIWiring.summarizerMoat(),
    modelGateMoat: ModelGateMoat = AIWiring.modelGateMoat()
  ) {
    self.policy = policy
    self.summarizerMoat = summarizerMoat
    self.modelGateMoat = modelGateMoat
    self.databaseURL = databaseURL
    self.databaseConfig = databaseConfig
    self.databaseEncryption = databaseEncryption
  }

  func load(seed: EscalationSeed) async {
    loadState = .loading
    let url = databaseURL
    let cfg = databaseConfig
    let enc = databaseEncryption
    let pol = policy
    do {
      let candidates: [ActivityFeedEntry]
      let preselect: Set<Int64>
      switch seed {
      case .ids(let entries):
        candidates = entries
        preselect = Set(entries.map(\.id))
      case .period(let p, _):
        let interval = p.interval()
        candidates = try await Task.detached(priority: .userInitiated) {
          try ActivityFeedQuery(dbURL: url, dbConfig: cfg, dbEncryption: enc)
            .fetch(period: interval)
        }.value
        preselect = []
      }
      let ids = candidates.map(\.id)
      let pairs = try await Task.detached(priority: .userInitiated) {
        try WorkFactGatherer(dbURL: url, dbConfig: cfg, dbEncryption: enc)
          .gatherSelectedBodiesKeyed(eventIDs: ids)
      }.value
      let preview = EscalationPreviewBuilder.preview(keyed: pairs, policy: pol)
      keyed = pairs
      draft = EscalationDraft(candidates: candidates, preview: preview, preselected: preselect)
      loadState = .ready
    } catch {
      loadState = .failed("Couldn't read those events right now. Try again.")
    }
  }

  func toggle(_ id: Int64) {
    draft?.toggle(id)
  }

  func retry() {
    draft?.reset()
  }

  func confirm(question: String, model: SummarizerModel?) async {
    guard var d = draft, d.beginSending() else { return }
    draft = d
    let ids = Array(d.selected).sorted()
    let events = keyed.filter { d.selected.contains($0.id) }.map(\.event)
    let a = ensureAnswerer()
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    let answer = await a.answer(
      question: question, eventIDs: ids, selectedEvents: events, nowMs: nowMs,
      path: .byok, preferred: model)
    switch answer {
    case .text(let text):
      draft?.resolve(answer: text)
    case .notEnoughData:
      draft?.fail("None of those events have text that can be sent.")
    case .failure(let message):
      draft?.fail(message)
    }
  }

  private func ensureAnswerer() -> AIDetailAnswerer {
    if let a = answerer { return a }
    let audit = DBEscalationAuditSink(
      dbURL: databaseURL, dbConfig: databaseConfig, dbEncryption: databaseEncryption)
    let a = AIDetailAnswerer(
      policy: policy, summarizer: summarizerMoat.summarizer, modelGate: modelGateMoat.gate,
      audit: audit, maxAnswerTokens: Self.maxAnswerTokens)
    answerer = a
    return a
  }
}
