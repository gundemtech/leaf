//
//  GoogleCalendarDetailViewModel.swift
//  Track 7 P2 — Google Calendar detail-screen state. Substrate is wired up
//  end-to-end (DetailRange-driven detached SQL into DerivedInsights
//  .googleCalendarActivityBreakdown(period:)), but the screen currently
//  ignores VM.state per spec §3.5 and renders a static empty-state until
//  the GCP verification gate clears. Keeping the full reload pipeline
//  here means the only edit to flip the surface on is the screen file.
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
final class GoogleCalendarDetailViewModel {
    enum State: Equatable {
        case loading
        case loaded(headline: DetailHeadline, breakdown: GoogleCalendarActivityBreakdown, daily: [Double])
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
    private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "google-calendar-detail")

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
            let result: Result<GoogleCalendarActivityBreakdown, Error> =
                await Task.detached(priority: .userInitiated) {
                    do {
                        let db = try LeafCore.Database.openForRead(at: url, config: cfg, encryption: enc)
                        let insights = DerivedInsightsFactory.make(database: db)
                        let breakdown = try insights.googleCalendarActivityBreakdown(period: interval)
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
                        daily: breakdown.dailyFocusMinutes
                    )
                }
            case .failure(let error):
                if error is CancellationError { return }
                self.logger.error("GoogleCalendar detail load failed: \(String(describing: error), privacy: .public)")
                self.state = .error("Couldn't load Calendar activity.")
            }
        }
    }

    private static func isEmpty(_ b: GoogleCalendarActivityBreakdown) -> Bool {
        b.focusBlockCount == 0 && b.oooBlockCount == 0 && b.workingLocationCount == 0
    }

    private static func headline(breakdown b: GoogleCalendarActivityBreakdown) -> DetailHeadline {
        let blocks = "\(b.focusBlockCount) focus block\(b.focusBlockCount == 1 ? "" : "s")"
        return DetailHeadline(value: "\(blocks) · \(formatHours(b.focusDurationSeconds))", trend: nil)
    }

    private static func formatHours(_ seconds: TimeInterval) -> String {
        let hours = seconds / 3600.0
        if hours >= 1 {
            return String(format: "%.1fh", hours)
        }
        let minutes = Int(seconds / 60.0)
        return "\(minutes)m"
    }
}
