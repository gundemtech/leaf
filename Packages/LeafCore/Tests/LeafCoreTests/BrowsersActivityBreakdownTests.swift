import XCTest
@testable import LeafCore

final class BrowsersActivityBreakdownTests: XCTestCase {

    func test_empty_isAllZeros() {
        let empty = BrowsersActivityBreakdown.empty
        XCTAssertEqual(empty.pageCount, 0)
        XCTAssertEqual(empty.domainCount, 0)
        XCTAssertEqual(empty.safariPageCount, 0)
        XCTAssertEqual(empty.chromePageCount, 0)
        XCTAssertEqual(empty.arcPageCount, 0)
        XCTAssertEqual(empty.safariActivationCount, 0)
        XCTAssertEqual(empty.chromeActivationCount, 0)
        XCTAssertEqual(empty.arcActivationCount, 0)
        XCTAssertTrue(empty.topDomains.isEmpty)
        XCTAssertEqual(empty.bookmarkEventCount, 0)
        XCTAssertTrue(empty.dailyNavigations.isEmpty)
    }

    func test_equatable_roundtrip() {
        let entry = DomainCountEntry(domain: "github.com", count: 42)
        let a = BrowsersActivityBreakdown(
            pageCount: 50,
            domainCount: 8,
            safariPageCount: 20,
            chromePageCount: 25,
            arcPageCount: 5,
            safariActivationCount: 30,
            chromeActivationCount: 35,
            arcActivationCount: 10,
            topDomains: [entry],
            bookmarkEventCount: 3,
            dailyNavigations: [5, 5, 5, 10, 10, 10, 5]
        )
        let aCopy = BrowsersActivityBreakdown(
            pageCount: 50,
            domainCount: 8,
            safariPageCount: 20,
            chromePageCount: 25,
            arcPageCount: 5,
            safariActivationCount: 30,
            chromeActivationCount: 35,
            arcActivationCount: 10,
            topDomains: [DomainCountEntry(domain: "github.com", count: 42)],
            bookmarkEventCount: 3,
            dailyNavigations: [5, 5, 5, 10, 10, 10, 5]
        )
        let b = BrowsersActivityBreakdown(
            pageCount: 99,
            domainCount: 8,
            safariPageCount: 20,
            chromePageCount: 25,
            arcPageCount: 5,
            safariActivationCount: 30,
            chromeActivationCount: 35,
            arcActivationCount: 10,
            topDomains: [entry],
            bookmarkEventCount: 3,
            dailyNavigations: [5, 5, 5, 10, 10, 10, 5]
        )
        XCTAssertEqual(a, aCopy)
        XCTAssertNotEqual(a, b)
    }

    func test_domainCountEntry_codableRoundtrip() throws {
        let original = DomainCountEntry(domain: "leaf.app", count: 7)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DomainCountEntry.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func test_cardPayload_init_assignsFields() {
        let payload = BrowsersCardPayload(
            pageCount: 100,
            domainCount: 25,
            safariCount: 40,
            chromeCount: 50,
            arcCount: 10,
            bookmarksAddedCount: 2,
            dailyNavigations: [10, 10, 10, 20, 20, 20, 10]
        )
        XCTAssertEqual(payload.pageCount, 100)
        XCTAssertEqual(payload.domainCount, 25)
        XCTAssertEqual(payload.safariCount, 40)
        XCTAssertEqual(payload.chromeCount, 50)
        XCTAssertEqual(payload.arcCount, 10)
        XCTAssertEqual(payload.bookmarksAddedCount, 2)
        XCTAssertEqual(payload.dailyNavigations.count, 7)
    }

    func test_sendable_acrossTaskBoundary() async {
        let breakdown = BrowsersActivityBreakdown.empty
        let echoed = await Task.detached { breakdown }.value
        XCTAssertEqual(echoed, breakdown)
    }
}
