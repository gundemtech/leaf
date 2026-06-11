//
//  AskLeafReader.swift
//  Leaf
//
//  AI-UI-1 — @Observable wrapper for the in-app "Ask Leaf" Q&A tab. Mirrors
//  HandoffDraftReader: gather off-main, per-ask path routing (AI-UI-4 — BYOK
//  key → Anthropic, otherwise team pool via the relay proxy).
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

  private let policy: LLMPolicy
  private let router: AIBackendRouter
  private let modelGateMoat: ModelGateMoat
  private let databaseURL: URL
  private let databaseConfig: DatabaseConfig
  private let databaseEncryption: EncryptionOptions?

  init(
    router: AIBackendRouter,
    databaseURL: URL = DatabasePath.defaultURL(),
    databaseConfig: DatabaseConfig = AIWiring.databaseConfig(),
    databaseEncryption: EncryptionOptions? = AIWiring.databaseEncryption(),
    policy: LLMPolicy = AIWiring.policy(),
    modelGateMoat: ModelGateMoat = AIWiring.modelGateMoat()
  ) {
    self.policy = policy
    self.router = router
    self.modelGateMoat = modelGateMoat
    self.databaseURL = databaseURL
    self.databaseConfig = databaseConfig
    self.databaseEncryption = databaseEncryption
  }

  var isAsking: Bool { transcript.hasPending }

  // AI-UI-3 — NL handoff-intent. Roster is scoped to the ACTIVE workspace
  // (CTO F1 — the send flow operates in it; an all-workspaces roster would
  // suggest cross-workspace recipients) and cached per workspace id. The
  // parser is pure LeafCore; a hit appends a TERMINAL suggestion entry (no
  // LLM call); bypassIntent re-runs the same question as plain Q&A.
  private var roster: [TeamMember] = []
  private var rosterWorkspaceID: String?

  func member(named name: String) -> TeamMember? {
    roster.first { $0.displayName == name }
  }

  private func ensureRoster(workspaceID: String?) async {
    guard let workspaceID else {
      roster = []
      rosterWorkspaceID = nil
      return
    }
    guard rosterWorkspaceID != workspaceID else { return }
    let url = databaseURL
    let cfg = databaseConfig
    let enc = databaseEncryption
    let members: [TeamMember]? = try? await Task.detached(priority: .userInitiated) {
      let db = try LeafCore.Database.openForRead(at: url, config: cfg, encryption: enc)
      return try db.readTeamMembers(workspaceID: workspaceID, includeRemoved: false)
    }.value
    // A failed read is NOT cached (review LOW-4) — a transient DB error must
    // not disable NL intent for the rest of the session; next ask retries.
    guard let members else {
      roster = []
      rosterWorkspaceID = nil
      return
    }
    roster = members
    rosterWorkspaceID = workspaceID
  }

  /// Ask one independent question over the period. No-op while a previous
  /// ask is pending (transcript enforces single-flight).
  func ask(
    question: String,
    period: ReviewActivityInsights.ReviewActivityPeriod,
    model: SummarizerModel?,
    activeWorkspaceID: String? = nil,
    bypassIntent: Bool = false
  ) async {
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

    if !bypassIntent {
      await ensureRoster(workspaceID: activeWorkspaceID)
      if let hit = HandoffIntentParser.parse(
        question: question, rosterNames: roster.map(\.displayName)),
        member(named: hit.recipientName) != nil
      {
        _ = transcript.suggestHandoff(
          question: question, recipientName: hit.recipientName, topic: hit.topic,
          period: period, askedAtMs: nowMs)
        return
      }
    }

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
        id: id,
        with: .failure(
          AIFailure(
            kind: .localRead, message: "Couldn't read your activity right now. Try again.")))
      return
    }

    // AI-UI-4 — resolve the backend per ask (BYOK valve: a key added/removed
    // in Settings flips the very next question).
    let r = router.resolve()
    let a = AIWorkAnswerer(policy: policy, summarizer: r.summarizer, modelGate: modelGateMoat.gate)
    let answer = await a.answer(
      question: question, events: events, path: r.path, preferred: model)
    transcript.resolve(id: id, with: answer)
  }
}
