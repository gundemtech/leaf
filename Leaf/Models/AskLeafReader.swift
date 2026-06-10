//
//  AskLeafReader.swift
//  Leaf
//
//  AI-UI-1 — @Observable wrapper for the in-app "Ask Leaf" Q&A tab. Mirrors
//  HandoffDraftReader: lazy AIWorkAnswerer bootstrap, gather off-main, BYOK-only.
//  Transcript model (ordering / single-flight / phase transitions) is pure
//  LeafCore (AskLeafTranscript) and SPM-tested; this class is glue.
//

import Foundation
import LeafCore
import Observation
import SwiftUI

@MainActor
@Observable
final class AskLeafReader {
  private(set) var transcript = AskLeafTranscript()

  private var answerer: AIWorkAnswerer?

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

  var isAsking: Bool { transcript.hasPending }

  /// Ask one independent question over the period. No-op while a previous
  /// ask is pending (transcript enforces single-flight).
  func ask(
    question: String,
    period: ReviewActivityInsights.ReviewActivityPeriod,
    model: SummarizerModel?
  ) async {
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    guard
      let id = transcript.ask(
        question: question, period: period, model: model, askedAtMs: nowMs)
    else { return }

    let url = databaseURL
    let cfg = databaseConfig
    let enc = databaseEncryption
    let interval = period.interval()
    let events: [EgressEvent]
    do {
      events = try await Task.detached(priority: .userInitiated) {
        try WorkFactGatherer(dbURL: url, dbConfig: cfg, dbEncryption: enc)
          .gather(period: interval, nowMs: nowMs)
      }.value
    } catch {
      transcript.resolve(
        id: id, with: .failure("Couldn't read your activity right now. Try again."))
      return
    }

    let a = ensureAnswerer()
    let answer = await a.answer(
      question: question, events: events, path: .byok, preferred: model)
    transcript.resolve(id: id, with: answer)
  }

  private func ensureAnswerer() -> AIWorkAnswerer {
    if let a = answerer { return a }
    let a = AIWorkAnswerer(
      policy: policy, summarizer: summarizerMoat.summarizer, modelGate: modelGateMoat.gate)
    answerer = a
    return a
  }
}
