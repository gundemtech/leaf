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
//  CR-2 (boundary parity): under LEAF_PROD this wires the SAME prod moat +
//  strict-mode reader as MCPServer.swift — `prodLLMEgressMoat()` (the bucket-1
//  personal-app list) + `StrictModeReader.read()`. The #if LEAF_PROD factory
//  defaults are the structural guard: the only build that gets the empty
//  substrate is dev, where there is no live LLM egress (mirrors
//  DirectMessageSendReader.defaultCodec's fail-closed posture).
//

import Foundation
import Observation
import OSLog
import SwiftUI
import LeafCore
#if LEAF_PROD
import LeafCorePrivate
#endif

@MainActor
@Observable
final class HandoffDraftReader {
  enum State: Equatable {
    case idle
    case drafting
    /// Carries the drafted text + provenance so the sheet can fill the editable
    /// body AND stash the provenance for the SEND-time audit.
    case drafted(text: String, provenance: HandoffProvenance)
    case error(message: String)
  }

  private(set) var state: State = .idle

  private var drafter: HandoffDrafter?

  private let policy: LLMPolicy
  private let summarizerMoat: AISummarizerMoat
  private let modelGateMoat: ModelGateMoat
  private let databaseURL: URL
  private let databaseConfig: DatabaseConfig
  private let databaseEncryption: EncryptionOptions?
  private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "handoff-draft")

  init(
    databaseURL: URL = DatabasePath.defaultURL(),
    databaseConfig: DatabaseConfig = HandoffDraftReader.defaultConfig(),
    databaseEncryption: EncryptionOptions? = HandoffDraftReader.defaultEncryption(),
    policy: LLMPolicy = HandoffDraftReader.defaultPolicy(),
    summarizerMoat: AISummarizerMoat = HandoffDraftReader.defaultSummarizerMoat(),
    modelGateMoat: ModelGateMoat = HandoffDraftReader.defaultModelGateMoat()
  ) {
    self.policy = policy
    self.summarizerMoat = summarizerMoat
    self.modelGateMoat = modelGateMoat
    self.databaseURL = databaseURL
    self.databaseConfig = databaseConfig
    self.databaseEncryption = databaseEncryption
  }

  func reset() {
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
      state = .error(message: "Couldn't read your activity right now. Try again.")
      return
    }

    let d = ensureDrafter()
    switch await d.draft(
      topic: topic, recipientName: recipientName, events: events, period: period, path: .byok)
    {
    case .text(let text, let provenance):
      state = .drafted(text: text, provenance: provenance)
    case .notEnoughData:
      state = .error(
        message: "Not enough recorded work in this period to draft a handoff. Type one yourself.")
    case .failure(let message):
      state = .error(message: message)
    }
  }

  // MARK: - Internal lazy bootstrap

  private func ensureDrafter() -> HandoffDrafter {
    if let d = drafter { return d }
    let d = HandoffDrafter(
      policy: policy, summarizer: summarizerMoat.summarizer, modelGate: modelGateMoat.gate)
    drafter = d
    return d
  }

  // MARK: - Composition-root defaults (CR-2 parity with MCPServer.swift)

  private static func defaultPolicy() -> LLMPolicy {
    #if LEAF_PROD
    return LLMPolicy(
      moat: prodLLMEgressMoat(), config: LLMPolicyConfig(strictMode: StrictModeReader.read()))
    #else
    return LLMPolicy(config: LLMPolicyConfig(strictMode: StrictModeReader.read()))
    #endif
  }

  private static func defaultSummarizerMoat() -> AISummarizerMoat {
    #if LEAF_PROD
    return prodAISummarizerMoat(keyStore: FileAnthropicKeyStore())
    #else
    return .publicSubstrate
    #endif
  }

  private static func defaultModelGateMoat() -> ModelGateMoat {
    #if LEAF_PROD
    return prodModelGateMoat()
    #else
    return .publicSubstrate
    #endif
  }

  private static func defaultConfig() -> DatabaseConfig {
    #if LEAF_PROD
    return ProdConfigs.database
    #else
    return DatabaseConfig.weakDefaults
    #endif
  }

  private static func defaultEncryption() -> EncryptionOptions? {
    #if LEAF_PROD
    return EncryptionOptions(
      keyProvider: .callback { @Sendable in try FileKeyStore.fetchOrCreate() },
      preKeyPragmas: ProdConfigs.sqlcipherPragmasPreKey,
      postKeyPragmas: ProdConfigs.sqlcipherPragmasPostKey
    )
    #else
    return nil
    #endif
  }

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
    databaseConfig: DatabaseConfig = HandoffAuditWriter.defaultConfig(),
    databaseEncryption: EncryptionOptions? = HandoffAuditWriter.defaultEncryption()
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

  private static func defaultConfig() -> DatabaseConfig {
    #if LEAF_PROD
    return ProdConfigs.database
    #else
    return DatabaseConfig.weakDefaults
    #endif
  }

  private static func defaultEncryption() -> EncryptionOptions? {
    #if LEAF_PROD
    return EncryptionOptions(
      keyProvider: .callback { @Sendable in try FileKeyStore.fetchOrCreate() },
      preKeyPragmas: ProdConfigs.sqlcipherPragmasPreKey,
      postKeyPragmas: ProdConfigs.sqlcipherPragmasPostKey
    )
    #else
    return nil
    #endif
  }
}
