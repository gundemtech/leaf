//
//  WorkStateDetailViewModel.swift
//  Track 7 P3 — detail-screen state. Owns DetailRange + WorkStateSubTab
//  selection; on range change, reloads the 4 D3 collections via
//  DerivedInsights work-state methods. SwiftUI body reads `state` directly.
//
//  Pipeline mirrors ClaudeCodeDetailViewModel from P1: @MainActor +
//  @Observable, detached Task with stale-result guard, error never crashes UI.
//

import Foundation
import LeafCore
import OSLog
import Observation

#if LEAF_PROD
import LeafCorePrivate
#endif

@MainActor
@Observable
final class WorkStateDetailViewModel {
    enum State: Equatable {
        case loading
        case loaded(WorkStateDetailPayload)
        case error(String)
    }

    private(set) var state: State = .loading
    var range: DetailRange = .default {
        didSet {
            guard range != oldValue else { return }
            reload()
        }
    }
    var subTab: WorkStateSubTab = .questions

    private let databaseURL: URL
    private let databaseConfig: DatabaseConfig
    private let databaseEncryption: EncryptionOptions?
    private let calendar: Calendar
    private let now: () -> Date
    private var task: Task<Void, Never>?
    private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "work-state-detail")

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
            let result: Result<WorkStateDetailPayload, Error> =
                await Task.detached(priority: .userInitiated) {
                    do {
                        let db = try LeafCore.Database.openForRead(at: url, config: cfg, encryption: enc)
                        let insights = DerivedInsightsFactory.make(database: db)

                        let decisions = try insights.recentDecisions(period: interval, limit: 30)
                        let questions = try insights.openQuestions(period: interval)
                        let blockers = try insights.openBlockers()
                        let whereStopped = try insights.recentWhereStopped(limit: 20)

                        let payload = WorkStateDetailPayload(
                            decisions: decisions,
                            questions: questions,
                            blockers: blockers,
                            whereStopped: whereStopped
                        )
                        return .success(payload)
                    } catch {
                        return .failure(error)
                    }
                }.value

            guard let self else { return }
            if Task.isCancelled { return }

            switch result {
            case .success(let payload):
                self.state = .loaded(payload)
            case .failure(let error):
                if error is CancellationError { return }
                self.logger.error("WorkState detail load failed: \(String(describing: error), privacy: .public)")
                self.state = .error("Couldn't load Work State.")
            }
        }
    }
}

/// Full payload for the detail screen — held inside `State.loaded`. Lists are
/// returned by DerivedInsights uncapped at protocol level; view-model caps to
/// top-30 (top-20 for whereStopped) at render time inside `WorkStateDetailScreen`.
///
/// IMPORTANT: do NOT cap the stored arrays inside this payload. The derived
/// `*Count` props below depend on the uncapped arrays — capping at this layer
/// would cause headline / aggregates to silently under-report. Cap only in the
/// view body when building the row list.
struct WorkStateDetailPayload: Equatable, Sendable, Hashable {
    let decisions: [Decision]
    let questions: [OpenQuestion]
    let blockers: [Blocker]
    let whereStopped: [WhereStoppedSnapshot]

    static let empty = WorkStateDetailPayload(
        decisions: [], questions: [], blockers: [], whereStopped: []
    )

    // MARK: - Derived counts (used by headline + aggregates per §4.2 §4.3)

    var openQuestionsCount: Int {
        questions.filter { $0.resolvedAtMs == nil }.count
    }

    var resolvedQuestionsCount: Int {
        questions.filter { $0.resolvedAtMs != nil }.count
    }

    var openBlockersCount: Int {
        blockers.filter { $0.resolvedAtMs == nil }.count
    }

    var resolvedBlockersCount: Int {
        blockers.filter { $0.resolvedAtMs != nil }.count
    }

    var decisionsCount: Int { decisions.count }

    var whereStoppedCount: Int { whereStopped.count }
}
