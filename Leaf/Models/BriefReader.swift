//
//  BriefReader.swift
//  UC-3 brief — loads the "what shipped" counters for the Home BriefBlock.
//  Two read paths composed into one snapshot:
//    • DerivedInsights.recentActivityFeed — PRs merged / tickets done /
//      commits / reviews over the period.
//    • QueryEngine.queryActivity — decisions surfaced + blockers resolved
//      in the period (detector tables; same engine the MCP tools use).
//

import Foundation
import LeafCore
import Observation

#if LEAF_PROD
  import LeafCorePrivate
#endif

@MainActor
@Observable
final class BriefReader {
  enum State: Equatable {
    case idle
    case loading
    case loaded(BriefSnapshot)
    case empty
    case error
  }

  private(set) var state: State = .idle

  nonisolated static let periodDays = 5

  private let dbURL: URL
  private var generation = 0

  init(databaseURL: URL = DatabasePath.defaultURL()) {
    self.dbURL = databaseURL
  }

  func refresh() async {
    guard FileManager.default.fileExists(atPath: dbURL.path) else {
      state = .empty
      return
    }
    generation += 1
    let myGeneration = generation
    if state == .idle { state = .loading }

    let url = dbURL
    let result: Result<BriefSnapshot, Error> = await Task.detached(priority: .utility) {
      do {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let periodStartMs = nowMs - Int64(Self.periodDays) * 86_400_000

        let db = try LeafCore.Database.openForRead(
          at: url, config: Self.dbConfig(), encryption: Self.dbEncryption())
        let insights = DerivedInsightsFactory.make(database: db)
        let feed = (try? insights.recentActivityFeed(since: periodStartMs, limit: 200)) ?? []

        let engine = QueryEngine(
          dbURL: url,
          dbConfig: Self.dbConfig(),
          dbEncryption: Self.dbEncryption(),
          detectorMoat: Self.detectorMoat()
        )
        let activity = try? engine.queryActivity(
          period: PeriodSpec(startMs: periodStartMs, endMs: nowMs), filter: nil)
        let decisions = activity?.decisionsInPeriod.count ?? 0
        let blockersResolved =
          activity?.blockers.count {
            ($0.resolvedAtMs ?? 0) >= periodStartMs && $0.resolvedAtMs != nil
          } ?? 0

        return .success(
          BriefComposer.compose(
            feed: feed,
            decisionsSurfaced: decisions,
            blockersResolved: blockersResolved,
            periodDays: Self.periodDays
          ))
      } catch {
        return .failure(error)
      }
    }.value

    guard myGeneration == generation else { return }
    switch result {
    case .success(let brief):
      state = brief.isEmpty ? .empty : .loaded(brief)
    case .failure:
      state = .error
    }
  }

  // MARK: - Build-flavor wiring (mirrors SearchReader)

  nonisolated private static func dbConfig() -> DatabaseConfig {
    #if LEAF_PROD
      return ProdConfigs.database
    #else
      return .weakDefaults
    #endif
  }

  nonisolated private static func dbEncryption() -> EncryptionOptions? {
    #if LEAF_PROD
      return EncryptionOptions(
        keyProvider: .callback { @Sendable in
          try FileKeyStore.fetchOrCreate()
        },
        preKeyPragmas: ProdConfigs.sqlcipherPragmasPreKey,
        postKeyPragmas: ProdConfigs.sqlcipherPragmasPostKey
      )
    #else
      return nil
    #endif
  }

  nonisolated private static func detectorMoat() -> DetectorMoat {
    #if LEAF_PROD
      return prodDetectorMoat()
    #else
      return .publicSubstrate
    #endif
  }
}
