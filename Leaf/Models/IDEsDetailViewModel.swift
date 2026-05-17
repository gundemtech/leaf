//
//  IDEsDetailViewModel.swift
//  Track 7 P2 — IDEs detail-screen state (VSCode-family + JetBrains +
//  fallback window-title combined). DetailRange-driven detached SQL into
//  DerivedInsights.idesActivityBreakdown(period:). Headline counts files
//  touched in N workspaces so the "wide vs deep" gestalt reads in one
//  glance.
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
final class IDEsDetailViewModel {
    enum State: Equatable {
        case loading
        case loaded(headline: DetailHeadline, breakdown: IDEsActivityBreakdown, daily: [Double])
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
    private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "ides-detail")

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
            let result: Result<IDEsActivityBreakdown, Error> =
                await Task.detached(priority: .userInitiated) {
                    do {
                        let db = try LeafCore.Database.openForRead(at: url, config: cfg, encryption: enc)
                        let insights = DerivedInsightsFactory.make(database: db)
                        let breakdown = try insights.idesActivityBreakdown(period: interval)
                        return .success(breakdown)
                    } catch {
                        return .failure(error)
                    }
                }.value

            guard let self else { return }
            if Task.isCancelled { return }

            switch result {
            case .success(let breakdown):
                if Self.isEmpty(breakdown) {
                    self.state = .empty
                } else {
                    self.state = .loaded(
                        headline: Self.headline(breakdown: breakdown),
                        breakdown: breakdown,
                        daily: breakdown.dailyEvents
                    )
                }
            case .failure(let error):
                if error is CancellationError { return }
                self.logger.error("IDEs detail load failed: \(String(describing: error), privacy: .public)")
                self.state = .error("Couldn't load IDE activity.")
            }
        }
    }

    private static func isEmpty(_ b: IDEsActivityBreakdown) -> Bool {
        b.totalEventCount == 0 && b.workspaceCount == 0
    }

    private static func headline(breakdown b: IDEsActivityBreakdown) -> DetailHeadline {
        let files = "\(b.totalEventCount) file\(b.totalEventCount == 1 ? "" : "s")"
        let workspaces = "\(b.workspaceCount) workspace\(b.workspaceCount == 1 ? "" : "s")"
        return DetailHeadline(value: "\(files) in \(workspaces)", trend: nil)
    }
}
