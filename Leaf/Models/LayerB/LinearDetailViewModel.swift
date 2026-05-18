//
//  LinearDetailViewModel.swift
//  Track 7 P4 — Linear detail screen state. Mirrors P1 ClaudeCodeDetailViewModel
//  shape: @MainActor @Observable + State enum + range binding с didSet reload +
//  detached Task pipeline для DB query.
//
//  Linear не имеет scope drift (OAuth scope `read` фиксирован) — нет
//  scopeBanner / dismiss state.
//
//  LinearActivityBreakdown already embeds transitions (breakdown.transitions),
//  so a single linearActivity(period:) call is sufficient — no second query.
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
final class LinearDetailViewModel {
    enum State: Equatable {
        case loading
        case loaded(
            headline: DetailHeadline,
            breakdown: LinearActivityBreakdown
        )
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
    private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "linear-detail")

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
            let result: Result<LinearActivityBreakdown, Error> =
                await Task.detached(priority: .userInitiated) {
                    do {
                        let db = try LeafCore.Database.openForRead(at: url, config: cfg, encryption: enc)
                        let insights = DerivedInsightsFactory.make(database: db)
                        let breakdown = try insights.linearActivity(period: interval)
                        return .success(breakdown)
                    } catch {
                        return .failure(error)
                    }
                }.value

            guard let self else { return }
            if Task.isCancelled { return }

            switch result {
            case .success(let breakdown):
                if breakdown.issuesTouched == 0 {
                    self.state = .empty
                } else {
                    let headline = LinearHeadlineFormatter.headline(breakdown: breakdown, range: self.range)
                    self.state = .loaded(headline: headline, breakdown: breakdown)
                }
            case .failure(let error):
                if error is CancellationError { return }
                self.logger.error("Linear detail load failed: \(String(describing: error), privacy: .public)")
                self.state = .error("Couldn't load Linear activity.")
            }
        }
    }
}
