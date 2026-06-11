//
//  SearchReader.swift
//  UC-1 in-app search — thin async wrapper over `QueryEngine` (the same
//  engine the MCP tools use; one query path, two surfaces). Debounce lives
//  in the view (`.task(id:)`); the reader does a single engine call per
//  `search(query:)` and composes display rows via `SearchResultsComposer`.
//

import Foundation
import LeafCore
import Observation

#if LEAF_PROD
  import LeafCorePrivate
#endif

@MainActor
@Observable
final class SearchReader {
  enum State: Equatable {
    case idle
    case searching
    case results([SearchResultRow])
    case empty
    case error(String)
  }

  private(set) var state: State = .idle

  /// FTS window — 90 days back from now. The events retention sweep keeps
  /// 60 days anyway; the wider window costs nothing and survives a retention
  /// bump without a code change here.
  nonisolated private static let searchWindowDays = 90

  private let dbURL: URL
  private var generation = 0

  init(databaseURL: URL = DatabasePath.defaultURL()) {
    self.dbURL = databaseURL
  }

  func search(query: String) async {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      state = .idle
      return
    }
    guard FileManager.default.fileExists(atPath: dbURL.path) else {
      state = .error("Enable background collection in Settings first.")
      return
    }
    generation += 1
    let myGeneration = generation
    state = .searching

    let url = dbURL
    let result: Result<[SearchResultRow], Error> = await Task.detached(priority: .userInitiated) {
      do {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let engine = QueryEngine(
          dbURL: url,
          dbConfig: Self.dbConfig(),
          dbEncryption: Self.dbEncryption(),
          detectorMoat: Self.detectorMoat()
        )
        let response = try engine.queryActivity(
          period: PeriodSpec(
            startMs: nowMs - Int64(Self.searchWindowDays) * 86_400_000, endMs: nowMs),
          filter: trimmed
        )
        return .success(SearchResultsComposer.compose(from: response))
      } catch {
        return .failure(error)
      }
    }.value

    // A newer query superseded this one while SQL ran — drop the stale result.
    guard myGeneration == generation else { return }

    switch result {
    case .success(let rows):
      state = rows.isEmpty ? .empty : .results(rows)
    case .failure:
      state = .error("Couldn't search your memory. Try again.")
    }
  }

  func reset() {
    generation += 1
    state = .idle
  }

  // MARK: - Build-flavor wiring (mirrors InsightsReader / MCP tools)

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
