//
//  XcodeDetailViewModel.swift
//  Track 7 P2 — Xcode detail-screen state. Mirrors ClaudeCodeDetailViewModel
//  shape: DetailRange-driven reload into a detached Task that opens a
//  read-only LeafCore.Database and calls DerivedInsights
//  .xcodeActivityBreakdown(period:). Headline pairs build + test counts so a
//  burndown-heavy session reads correctly even when one axis is zero.
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
final class XcodeDetailViewModel {
    enum State: Equatable {
        case loading
        case loaded(headline: DetailHeadline, breakdown: XcodeActivityBreakdown, daily: [Double])
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
    private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "xcode-detail")

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
            let result: Result<XcodeActivityBreakdown, Error> =
                await Task.detached(priority: .userInitiated) {
                    do {
                        let db = try LeafCore.Database.openForRead(at: url, config: cfg, encryption: enc)
                        let insights = DerivedInsightsFactory.make(database: db)
                        let breakdown = try insights.xcodeActivityBreakdown(period: interval)
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
                        daily: breakdown.dailyBuilds
                    )
                }
            case .failure(let error):
                if error is CancellationError { return }
                self.logger.error("Xcode detail load failed: \(String(describing: error), privacy: .public)")
                self.state = .error("Couldn't load Xcode activity.")
            }
        }
    }

    private static func isEmpty(_ b: XcodeActivityBreakdown) -> Bool {
        b.buildCount == 0 && b.testRunCount == 0
    }

    private static func headline(breakdown b: XcodeActivityBreakdown) -> DetailHeadline {
        let buildsLabel = "\(b.buildCount) build\(b.buildCount == 1 ? "" : "s")"
        let testsLabel = "\(b.testRunCount) test\(b.testRunCount == 1 ? "" : "s")"
        return DetailHeadline(value: "\(buildsLabel) · \(testsLabel)", trend: nil)
    }
}
