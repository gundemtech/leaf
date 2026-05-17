//
//  GitHubDetailViewModel.swift
//  Track 7 P4 — GitHub detail screen state. Mirrors LinearDetailViewModel
//  but querying githubActivity + ReviewActivityInsights.reviewActivity()
//  (only когда range ∈ {.today, .week} — .month не имеет mapping).
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
final class GitHubDetailViewModel {
    enum State: Equatable {
        case loading
        case loaded(
            headline: DetailHeadline,
            breakdown: GitHubActivityBreakdown,
            reviewActivity: ReviewActivityResult?
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

    /// Per-launch dismiss state. Shared с HomeView через UserDefaults key
    /// "github.reauth.bannerDismissedSessionID" + AppSessionID.current.
    /// HomeView dismiss → also hides banner here, vice versa.
    var scopeBannerDismissed: Bool {
        get {
            guard let saved = UserDefaults.standard.string(forKey: Self.reauthBannerDismissKey) else {
                return false
            }
            return saved == AppSessionID.current
        }
        set {
            if newValue {
                UserDefaults.standard.set(AppSessionID.current, forKey: Self.reauthBannerDismissKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.reauthBannerDismissKey)
            }
        }
    }

    /// Mirror HomeView's reauthBannerDismissKey — see HomeView.swift line ~88.
    /// Hardcoded string (not hoisted to shared constants) — P11 carry-over.
    private static let reauthBannerDismissKey = "github.reauth.bannerDismissedSessionID"

    private let databaseURL: URL
    private let databaseConfig: DatabaseConfig
    private let databaseEncryption: EncryptionOptions?
    private let calendar: Calendar
    private let now: () -> Date
    private var task: Task<Void, Never>?
    private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "github-detail")

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
        let rng = range
        let url = databaseURL
        let cfg = databaseConfig
        let enc = databaseEncryption

        let reviewPeriod = Self.reviewPeriod(for: rng)

        task = Task { [weak self] in
            let result: Result<(GitHubActivityBreakdown, ReviewActivityResult?), Error> =
                await Task.detached(priority: .userInitiated) {
                    do {
                        let db = try LeafCore.Database.openForRead(at: url, config: cfg, encryption: enc)
                        let insights = DerivedInsightsFactory.make(database: db)
                        let breakdown = try insights.githubActivity(period: interval)

                        let reviewActivity: ReviewActivityResult?
                        if let reviewPeriod = reviewPeriod {
                            let rawDict = try ReviewActivityInsights.reviewActivity(
                                database: db,
                                period: reviewPeriod
                            )
                            reviewActivity = ReviewActivityResult.decode(rawDict)
                        } else {
                            reviewActivity = nil
                        }
                        return .success((breakdown, reviewActivity))
                    } catch {
                        return .failure(error)
                    }
                }.value

            guard let self else { return }
            if Task.isCancelled { return }

            switch result {
            case .success(let (breakdown, reviewActivity)):
                let reviewEmpty = (reviewActivity?.reviewsSubmittedCount ?? 0) +
                                  (reviewActivity?.reviewCommentsCount ?? 0) +
                                  (reviewActivity?.reviewThreadResolvedCount ?? 0) == 0
                if breakdown.eventsCount == 0 && reviewEmpty {
                    self.state = .empty
                } else {
                    let headline = GitHubHeadlineFormatter.headline(breakdown: breakdown, range: self.range)
                    self.state = .loaded(headline: headline, breakdown: breakdown, reviewActivity: reviewActivity)
                }
            case .failure(let error):
                if error is CancellationError { return }
                self.logger.error("GitHub detail load failed: \(String(describing: error), privacy: .public)")
                self.state = .error("Couldn't load GitHub activity.")
            }
        }
    }

    private static func reviewPeriod(for range: DetailRange) -> ReviewActivityInsights.ReviewActivityPeriod? {
        switch range {
        case .today: .today
        case .week:  .last7Days
        case .month: nil
        }
    }
}
