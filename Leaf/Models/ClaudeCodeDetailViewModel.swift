//
//  ClaudeCodeDetailViewModel.swift
//  Track 7 P1 — detail-screen state. Owns DetailRange selection; on change,
//  re-queries DerivedInsights.aiActivityBreakdown(period:). Loads in a
//  detached Task on appear and on range change; SwiftUI body reads `state`
//  directly.
//
//  P1 headline: sessionCount (not tokens) — AIActivityBreakdown does not
//  carry a tokensTotal field and aggregating raw claude_tokens_used events
//  for the headline requires a separate SQL helper that's out of scope for
//  P1. Tokens come back as the headline once that SQL helper lands (carry-
//  over to a future phase).
//

import Foundation
import Observation
import OSLog
import LeafCore
#if LEAF_PROD
import LeafCorePrivate
#endif

@MainActor
@Observable
final class ClaudeCodeDetailViewModel {
    enum State: Equatable {
        case loading
        case loaded(headline: DetailHeadline, breakdown: AIActivityBreakdown, daily: [Double])
        case empty
        case error(String)
    }

    private(set) var state: State = .loading
    var range: DetailRange = .default {
        didSet {
            guard range != oldValue else { return }
            reload()
        }
    }

    private let databaseURL: URL
    private let databaseConfig: DatabaseConfig
    private let databaseEncryption: EncryptionOptions?
    private let calendar: Calendar
    private let now: () -> Date
    private var task: Task<Void, Never>?
    private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "claude-code-detail")

    init(
        databaseURL: URL = DatabasePath.defaultURL(),
        databaseConfig: DatabaseConfig = InsightsReader.defaultConfig(),
        databaseEncryption: EncryptionOptions? = InsightsReader.defaultEncryption(),
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init
    ) {
        self.databaseURL = databaseURL
        self.databaseConfig = databaseConfig
        self.databaseEncryption = databaseEncryption
        self.calendar = calendar
        self.now = now
    }

    func reload() {
        task?.cancel()
        state = .loading
        let interval = range.interval(now: now(), calendar: calendar)
        let url = databaseURL
        let cfg = databaseConfig
        let enc = databaseEncryption
        task = Task { [weak self] in
            let result: Result<AIActivityBreakdown, Error> =
                await Task.detached(priority: .userInitiated) {
                    do {
                        let db = try LeafCore.Database.openForRead(at: url, config: cfg, encryption: enc)
                        let insights = DerivedInsightsFactory.make(database: db)
                        let breakdown = try insights.aiActivityBreakdown(period: interval)
                        return .success(breakdown)
                    } catch {
                        return .failure(error)
                    }
                }.value

            guard let self else { return }
            // Outer task was cancelled by a later reload() while we were
            // awaiting the detached inner Task (which is unstructured and
            // doesn't propagate cancellation). Drop the stale result so it
            // can't overwrite the .loading set by the more-recent reload().
            if Task.isCancelled { return }

            switch result {
            case .success(let breakdown):
                if breakdown.sessionCount == 0 && breakdown.aiActiveSeconds == 0 {
                    self.state = .empty
                } else {
                    let value = "\(breakdown.sessionCount) session\(breakdown.sessionCount == 1 ? "" : "s")"
                    let headline = DetailHeadline(value: value, trend: nil)
                    self.state = .loaded(headline: headline, breakdown: breakdown, daily: [])
                }
            case .failure(let error):
                if error is CancellationError { return }
                self.logger.error("ClaudeCode detail load failed: \(String(describing: error), privacy: .public)")
                self.state = .error("Couldn't load Claude Code activity.")
            }
        }
    }
}
