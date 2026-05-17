import Foundation

public struct BrowsersActivityBreakdown: Sendable, Hashable {
    public let pageCount: Int
    public let domainCount: Int
    public let safariPageCount: Int
    public let chromePageCount: Int
    public let arcPageCount: Int
    /// `*_tab_activated` sub-stat (OQ-T7P2-2 — surfaces engagement intensity
    /// separately from navigation count).
    public let safariActivationCount: Int
    public let chromeActivationCount: Int
    public let arcActivationCount: Int
    /// Top 5 domains by navigation count, descending.
    public let topDomains: [DomainCountEntry]
    public let bookmarkEventCount: Int
    /// 7 values (oldest → newest).
    public let dailyNavigations: [Double]

    public init(
        pageCount: Int,
        domainCount: Int,
        safariPageCount: Int,
        chromePageCount: Int,
        arcPageCount: Int,
        safariActivationCount: Int,
        chromeActivationCount: Int,
        arcActivationCount: Int,
        topDomains: [DomainCountEntry],
        bookmarkEventCount: Int,
        dailyNavigations: [Double]
    ) {
        self.pageCount = pageCount
        self.domainCount = domainCount
        self.safariPageCount = safariPageCount
        self.chromePageCount = chromePageCount
        self.arcPageCount = arcPageCount
        self.safariActivationCount = safariActivationCount
        self.chromeActivationCount = chromeActivationCount
        self.arcActivationCount = arcActivationCount
        self.topDomains = topDomains
        self.bookmarkEventCount = bookmarkEventCount
        self.dailyNavigations = dailyNavigations
    }

    public static let empty = BrowsersActivityBreakdown(
        pageCount: 0,
        domainCount: 0,
        safariPageCount: 0,
        chromePageCount: 0,
        arcPageCount: 0,
        safariActivationCount: 0,
        chromeActivationCount: 0,
        arcActivationCount: 0,
        topDomains: [],
        bookmarkEventCount: 0,
        dailyNavigations: []
    )
}

public struct DomainCountEntry: Sendable, Hashable, Codable {
    public let domain: String
    public let count: Int

    public init(domain: String, count: Int) {
        self.domain = domain
        self.count = count
    }
}
