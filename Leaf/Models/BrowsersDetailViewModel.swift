//
//  BrowsersDetailViewModel.swift
//  Track 7 P2 — Browsers detail-screen state (Safari + Chrome + Arc
//  combined, allow-listed domains only). DetailRange-driven detached SQL
//  into DerivedInsights.browsersActivityBreakdown(period:). Headline pairs
//  page count + domain count so research-day breadth shows even when
//  individual domains are deduped.
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
final class BrowsersDetailViewModel {
    enum State: Equatable {
        case loading
        case loaded(headline: DetailHeadline, breakdown: BrowsersActivityBreakdown, daily: [Double])
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
    private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "browsers-detail")

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
            let result: Result<BrowsersActivityBreakdown, Error> =
                await Task.detached(priority: .userInitiated) {
                    do {
                        let db = try LeafCore.Database.openForRead(at: url, config: cfg, encryption: enc)
                        let insights = DerivedInsightsFactory.make(database: db)
                        let breakdown = try insights.browsersActivityBreakdown(period: interval)
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
                        daily: breakdown.dailyNavigations
                    )
                }
            case .failure(let error):
                if error is CancellationError { return }
                self.logger.error("Browsers detail load failed: \(String(describing: error), privacy: .public)")
                self.state = .error("Couldn't load browser activity.")
            }
        }
    }

    private static func isEmpty(_ b: BrowsersActivityBreakdown) -> Bool {
        b.pageCount == 0
    }

    private static func headline(breakdown b: BrowsersActivityBreakdown) -> DetailHeadline {
        let pages = "\(b.pageCount) page\(b.pageCount == 1 ? "" : "s")"
        let domains = "\(b.domainCount) domain\(b.domainCount == 1 ? "" : "s")"
        return DetailHeadline(value: "\(pages) on \(domains)", trend: nil)
    }
}
