//
//  AIPrivacyFeedsReader.swift
//  Leaf
//
//  AI-UI-2 — reader двух Privacy-лент (Settings → Sharing → AI privacy):
//  «AI received» (ai_escalation_audit, M031) и «AI handoffs» (handoff_audit,
//  M032). Read-only; формат строк — LeafCore AIPrivacyFeedPresentation
//  (SPM-tested), это глуe. Тела в таблицах структурно отсутствуют.
//

import Foundation
import LeafCore
import Observation

@MainActor
@Observable
final class AIPrivacyFeedsReader {
  static let feedLimit = 50

  enum State {
    case loading
    case loaded(
      escalations: [AIPrivacyFeedPresentation.EscalationRow],
      handoffs: [AIPrivacyFeedPresentation.HandoffRow])
    case error(String)
  }

  private(set) var state: State = .loading

  private let databaseURL: URL
  private let databaseConfig: DatabaseConfig
  private let databaseEncryption: EncryptionOptions?

  init(
    databaseURL: URL = DatabasePath.defaultURL(),
    databaseConfig: DatabaseConfig = AIWiring.databaseConfig(),
    databaseEncryption: EncryptionOptions? = AIWiring.databaseEncryption()
  ) {
    self.databaseURL = databaseURL
    self.databaseConfig = databaseConfig
    self.databaseEncryption = databaseEncryption
  }

  func refresh() async {
    let url = databaseURL
    let cfg = databaseConfig
    let enc = databaseEncryption
    let limit = Self.feedLimit
    do {
      let (escalations, handoffs) = try await Task.detached(priority: .userInitiated) {
        let db = try LeafCore.Database.openForRead(at: url, config: cfg, encryption: enc)
        let escalationEntries = try db.recentAIEscalationAudit(limit: limit)
        let handoffEntries = try db.recentHandoffAudit(limit: limit)
        let members = try db.listWorkspaces(includeLeft: true).flatMap { ws in
          try db.readTeamMembers(workspaceID: ws.id, includeRemoved: true)
        }
        return (
          AIPrivacyFeedPresentation.escalationRows(escalationEntries),
          AIPrivacyFeedPresentation.handoffRows(handoffEntries, members: members)
        )
      }.value
      state = .loaded(escalations: escalations, handoffs: handoffs)
    } catch {
      state = .error("Couldn't read the AI privacy log right now.")
    }
  }
}
