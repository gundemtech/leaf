//
//  ZoomDetailViewModel.swift
//  Track 7 P2 — Zoom detail-screen state. DetailRange-driven detached SQL
//  into DerivedInsights.zoomActivityBreakdown(period:). Headline favours
//  total meeting time when non-zero (the "how heavy was meeting load"
//  read) and falls back to meeting count when duration is 0 but a meeting
//  did happen.
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
final class ZoomDetailViewModel {
    enum State: Equatable {
        case loading
        case loaded(headline: DetailHeadline, breakdown: ZoomActivityBreakdown, daily: [Double])
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
    private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "zoom-detail")

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
            let result: Result<ZoomActivityBreakdown, Error> =
                await Task.detached(priority: .userInitiated) {
                    do {
                        let db = try LeafCore.Database.openForRead(at: url, config: cfg, encryption: enc)
                        let insights = DerivedInsightsFactory.make(database: db)
                        let breakdown = try insights.zoomActivityBreakdown(period: interval)
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
                        daily: breakdown.dailyMinutes
                    )
                }
            case .failure(let error):
                if error is CancellationError { return }
                self.logger.error("Zoom detail load failed: \(String(describing: error), privacy: .public)")
                self.state = .error("Couldn't load Zoom activity.")
            }
        }
    }

    private static func isEmpty(_ b: ZoomActivityBreakdown) -> Bool {
        b.meetingCount == 0
    }

    private static func headline(breakdown b: ZoomActivityBreakdown) -> DetailHeadline {
        if b.totalDurationSeconds > 0 {
            return DetailHeadline(value: "\(formatHours(b.totalDurationSeconds)) meeting time", trend: nil)
        }
        let value = "\(b.meetingCount) meeting\(b.meetingCount == 1 ? "" : "s")"
        return DetailHeadline(value: value, trend: nil)
    }

    static func formatHours(_ seconds: TimeInterval) -> String {
        let hours = seconds / 3600.0
        if hours >= 1 {
            return String(format: "%.1fh", hours)
        }
        let minutes = Int(seconds / 60.0)
        return "\(minutes)m"
    }
}
