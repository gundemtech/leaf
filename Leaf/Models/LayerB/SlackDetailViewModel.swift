//
//  SlackDetailViewModel.swift
//  Track 7 P4 — Slack detail screen state. Mirrors GitHubDetailViewModel
//  но без ReviewActivityInsights — Slack breakdown стандартный.
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
final class SlackDetailViewModel {
    enum State: Equatable {
        case loading
        case loaded(headline: DetailHeadline, breakdown: SlackActivityBreakdown)
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

    /// Per-launch dismiss state. Shared с HomeView через `ReauthBannerKeys.slack`
    /// UserDefaults key + AppSessionID.current pattern.
    var scopeBannerDismissed: Bool {
        get { ReauthBannerKeys.isDismissed(ReauthBannerKeys.slack) }
        set {
            if newValue {
                ReauthBannerKeys.markDismissed(ReauthBannerKeys.slack)
            } else {
                ReauthBannerKeys.clearDismissed(ReauthBannerKeys.slack)
            }
        }
    }

    private let databaseURL: URL
    private let databaseConfig: DatabaseConfig
    private let databaseEncryption: EncryptionOptions?
    private let calendar: Calendar
    private let now: () -> Date
    private var task: Task<Void, Never>?
    private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "slack-detail")

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
            let result: Result<SlackActivityBreakdown, Error> =
                await Task.detached(priority: .userInitiated) {
                    do {
                        let db = try LeafCore.Database.openForRead(at: url, config: cfg, encryption: enc)
                        let insights = DerivedInsightsFactory.make(database: db)
                        let breakdown = try insights.slackActivity(period: interval)
                        return .success(breakdown)
                    } catch {
                        return .failure(error)
                    }
                }.value

            guard let self else { return }
            if Task.isCancelled { return }

            switch result {
            case .success(let breakdown):
                if breakdown.messagesCount == 0 && breakdown.huddleMinutes == 0 {
                    self.state = .empty
                } else {
                    let headline = SlackHeadlineFormatter.headline(breakdown: breakdown, range: self.range)
                    self.state = .loaded(headline: headline, breakdown: breakdown)
                }
            case .failure(let error):
                if error is CancellationError { return }
                self.logger.error("Slack detail load failed: \(String(describing: error), privacy: .public)")
                self.state = .error("Couldn't load Slack activity.")
            }
        }
    }
}
