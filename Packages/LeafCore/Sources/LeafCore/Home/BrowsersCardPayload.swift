import Foundation

public struct BrowsersCardPayload: Equatable, Sendable {
    /// Count of `*_tab_navigated` events across all 3 browsers.
    public let pageCount: Int
    /// Distinct domains observed in the period.
    public let domainCount: Int
    public let safariCount: Int
    public let chromeCount: Int
    public let arcCount: Int
    /// Sum of positive `delta_count` from `*_bookmark_count_changed` events.
    public let bookmarksAddedCount: Int
    /// 7 values (oldest → newest). Empty array means "spark not yet computed".
    public let dailyNavigations: [Double]

    public init(
        pageCount: Int,
        domainCount: Int,
        safariCount: Int,
        chromeCount: Int,
        arcCount: Int,
        bookmarksAddedCount: Int,
        dailyNavigations: [Double]
    ) {
        self.pageCount = pageCount
        self.domainCount = domainCount
        self.safariCount = safariCount
        self.chromeCount = chromeCount
        self.arcCount = arcCount
        self.bookmarksAddedCount = bookmarksAddedCount
        self.dailyNavigations = dailyNavigations
    }
}
