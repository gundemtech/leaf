//
//  ActivityFeedReader.swift
//  Leaf
//
//  AI-UI-2 — живой источник Activity Raw events (замена выпиленного в IV.A.2
//  protocol-метода). Зеркало AskLeafReader: AIWiring-дефолты, fetch off-main.
//  Логика выборки/маппинга — LeafCore (ActivityFeedQuery, SPM-tested); это глуe.
//

import Foundation
import LeafCore
import Observation

@MainActor
@Observable
final class ActivityFeedReader {
  enum State {
    case loading
    case loaded([ActivityFeedEntry])
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
    let period = DateInterval(start: Calendar.current.startOfDay(for: Date()), end: Date())
    do {
      let entries = try await Task.detached(priority: .userInitiated) {
        try ActivityFeedQuery(dbURL: url, dbConfig: cfg, dbEncryption: enc).fetch(period: period)
      }.value
      state = .loaded(entries)
    } catch {
      state = .error("Couldn't read today's events. Try again.")
    }
  }
}
