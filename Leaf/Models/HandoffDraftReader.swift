//
//  HandoffDraftReader.swift
//  Leaf
//
//  Track AI Coworker P4 — @Observable wrapper for the in-app team-handoff DRAFT
//  flow (§6/§13.6). State machine drives the "Draft with AI" affordance in
//  SendDirectMessageSheet: .idle → .drafting → (.drafted / .error). The approved
//  text is then delivered E2E by the EXISTING DirectMessageSendReader; this
//  reader only produces the draft + carries body-free provenance for the
//  SEND-time M032 audit (written by HandoffAuditWriter).
//
//  CR-2 (boundary parity): default wiring comes from AIWiring (AI-UI-1) —
//  under LEAF_PROD the SAME prod moat + strict-mode reader as MCPServer.swift;
//  the only build that gets the empty substrate is dev, where there is no
//  live LLM egress (mirrors DirectMessageSendReader.defaultCodec's
//  fail-closed posture).
//

import Foundation
import Observation
import OSLog
import SwiftUI
import LeafCore

@MainActor
@Observable
final class HandoffDraftReader {
  enum State: Equatable {
    case idle
    case drafting
    /// Carries the drafted text + provenance so the sheet can fill the editable
    /// body AND stash the provenance for the SEND-time audit.
    case drafted(text: String, provenance: HandoffProvenance)
    case error(AIFailure)
  }

  private(set) var state: State = .idle

  /// Review MEDIUM-2 — generation guard against late-completion contamination:
  /// reset() / every new request bumps the epoch; an in-flight draft that
  /// finishes after a reset (kind switched away, sheet dismissed, another
  /// recipient's sheet opened) publishes nothing. Without this, a stale
  /// .drafted could refill bodyText + provenance under a Task/Ping kind or a
  /// different recipient — and the M032 row would lie.
  private var epoch = 0

  private let policy: LLMPolicy
  private let router: AIBackendRouter
  private let modelGateMoat: ModelGateMoat
  private let promptMoat: HandoffPromptMoat
  private let databaseURL: URL
  private let databaseConfig: DatabaseConfig
  private let databaseEncryption: EncryptionOptions?
  private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "handoff-draft")

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
    epoch += 1
    state = .idle
  }

  /// Gather body-free facts for the period, draft a handoff note about `topic`
  /// for `recipientName`. The gather (a bounded SQL read) runs off the main
  /// actor; the LLM call suspends. `period` is stamped into provenance.
  func draft(
    recipientName: String,
    topic: String,
    period: DateInterval = HandoffDraftReader.defaultPeriod()
  ) async {
    epoch += 1
    let myEpoch = epoch
    state = .drafting

    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    let url = databaseURL
    let cfg = databaseConfig
    let enc = databaseEncryption
    let events: [EgressEvent]
    do {
      events = try await Task.detached(priority: .userInitiated) {
        try WorkFactGatherer(dbURL: url, dbConfig: cfg, dbEncryption: enc)
          .gather(period: period, nowMs: nowMs)
      }.value
    } catch {
      if epoch == myEpoch {
        state = .error(
          AIFailure(
            kind: .localRead, message: "Couldn't read your activity right now. Try again."))
      }
      return
    }

    // AI-UI-4 — resolve the backend per draft (BYOK valve).
    let r = router.resolve()
    let d = makeDrafter(summarizer: r.summarizer)
    let outcome = await d.draft(
      topic: topic, recipientName: recipientName, events: events, period: period, path: r.path)
    guard epoch == myEpoch else { return }  // superseded — publish nothing
    switch outcome {
    case .text(let text, let provenance):
      state = .drafted(text: text, provenance: provenance)
    case .notEnoughData:
      state = .error(
        AIFailure(
          kind: .localRead,
          message: "Not enough recorded work in this period to draft a handoff. Type one yourself."))
    case .failure(let failure):
      state = .error(failure)
    }
  }

  /// AI-UI-3 — escalated redraft: re-gathers body-free facts for the period,
  /// fetches the CONSENTED selected bodies, and drafts again with them. The
  /// audit-first M031 write happens inside HandoffDrafter. bodyText is filled
  /// on .drafted only — a failed redraft never clears the user's prior draft.
  func redraft(
    recipientName: String,
    topic: String,
    period: DateInterval,
    selectedEventIDs: [Int64]
  ) async {
    epoch += 1
    let myEpoch = epoch
    state = .drafting
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    let url = databaseURL
    let cfg = databaseConfig
    let enc = databaseEncryption
    let capped = Array(selectedEventIDs.sorted().prefix(EscalationDraft.selectionCap))
    let events: [EgressEvent]
    let keyed: [(id: Int64, event: EgressEvent)]
    do {
      (events, keyed) = try await Task.detached(priority: .userInitiated) {
        let gatherer = WorkFactGatherer(dbURL: url, dbConfig: cfg, dbEncryption: enc)
        return (
          try gatherer.gather(period: period, nowMs: nowMs),
          try gatherer.gatherSelectedBodiesKeyed(eventIDs: capped)
        )
      }.value
    } catch {
      if epoch == myEpoch {
        state = .error(
          AIFailure(
            kind: .localRead, message: "Couldn't read your activity right now. Try again."))
      }
      return
    }

    let escalated = policy.makeEscalation(selected: keyed.map(\.event))
    // AI-UI-4 — resolve the backend per redraft (BYOK valve).
    let r = router.resolve()
    let d = makeDrafter(summarizer: r.summarizer)
    // Audit records the CONSENTED ids (`capped`), not the rows found at redraft
    // time — P3 precedent: the consent act is what's audited (review LOW-5).
    let outcome = await d.draft(
      topic: topic, recipientName: recipientName, events: events, period: period,
      path: r.path, escalated: escalated, escalatedEventIDs: capped)
    guard epoch == myEpoch else { return }  // superseded — publish nothing
    switch outcome {
    case .text(let text, let provenance):
      state = .drafted(text: text, provenance: provenance)
    case .notEnoughData:
      state = .error(
        AIFailure(
          kind: .localRead,
          message: "Not enough recorded work in this period to draft a handoff. Type one yourself."))
    case .failure(let failure):
      state = .error(failure)
    }
  }

  // MARK: - Internal lazy bootstrap

  private func makeDrafter(summarizer: any Summarizer) -> HandoffDrafter {
    // AI-UI-3 — the prompt seam + M031 sink ride along; the sink is only used
    // on the escalated redraft path (body-free drafts stay un-audited, parity).
    let audit = DBEscalationAuditSink(
      dbURL: databaseURL, dbConfig: databaseConfig, dbEncryption: databaseEncryption)
    return HandoffDrafter(
      policy: policy, summarizer: summarizer, modelGate: modelGateMoat.gate,
      prompts: promptMoat.prompts, audit: audit)
  }

  // MARK: - Defaults
  // Composition-root AI/DB wiring lives in AIWiring (AI-UI-1) — shared with
  // HandoffAuditWriter and AskLeafReader.

  static func defaultPeriod() -> DateInterval {
    let now = Date()
    return DateInterval(start: now.addingTimeInterval(-7 * 86_400), end: now)
  }
}

/// Track AI Coworker P4 — opens a brief writer handle and appends ONE M032
/// `handoff_audit` row after an AI-assisted handoff DM is successfully sent
/// (mirrors P3's `DBEscalationAuditSink`). Decoupled from the generic
/// `DirectMessageSendReader` so no AI provenance leaks into the transport reader.
/// Best-effort: the DM already sent; a failed audit write is logged, not surfaced.
struct HandoffAuditWriter {
  let databaseURL: URL
  let databaseConfig: DatabaseConfig
  let databaseEncryption: EncryptionOptions?

  init(
    databaseURL: URL = DatabasePath.defaultURL(),
    databaseConfig: DatabaseConfig = AIWiring.databaseConfig(),
    databaseEncryption: EncryptionOptions? = AIWiring.databaseEncryption()
  ) {
    self.databaseURL = databaseURL
    self.databaseConfig = databaseConfig
    self.databaseEncryption = databaseEncryption
  }

  func record(
    messageID: String?,
    recipientMemberID: String?,
    provenance: HandoffProvenance,
    crosspostedSlack: Bool,
    crosspostedLinear: Bool,
    nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
  ) async throws {
    let url = databaseURL
    let cfg = databaseConfig
    let enc = databaseEncryption
    try await Task.detached(priority: .utility) {
      let db = try LeafCore.Database.openForWrite(at: url, config: cfg, encryption: enc)
      try db.appendHandoffAudit(
        generatedAtMs: nowMs,
        messageID: messageID,
        recipientMemberID: recipientMemberID,
        model: provenance.model,
        path: provenance.path,
        periodStartMs: provenance.periodStartMs,
        periodEndMs: provenance.periodEndMs,
        factCount: provenance.factCount,
        escalated: provenance.escalated,
        crosspostedSlack: crosspostedSlack,
        crosspostedLinear: crosspostedLinear,
        sourceSummary: provenance.sourceSummary,
        topicExcerpt: provenance.topicExcerpt)
    }.value
  }

}
