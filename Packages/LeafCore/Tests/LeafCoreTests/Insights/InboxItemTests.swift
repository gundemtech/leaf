import XCTest
@testable import LeafCore

final class InboxItemTests: XCTestCase {
    func testInboxKindRawValues() {
        XCTAssertEqual(InboxKind.reviewRequest.rawValue, "reviewRequest")
        XCTAssertEqual(InboxKind.commentOnMyWork.rawValue, "commentOnMyWork")
        XCTAssertEqual(InboxKind.mention.rawValue, "mention")
        XCTAssertEqual(InboxKind.openQuestion.rawValue, "openQuestion")
        XCTAssertEqual(InboxKind.blocker.rawValue, "blocker")
    }

    func testInboxFilterValues() {
        XCTAssertEqual(InboxFilter.all.rawValue, "all")
        XCTAssertEqual(InboxFilter.reviews.rawValue, "reviews")
        XCTAssertEqual(InboxFilter.questions.rawValue, "questions")
        XCTAssertEqual(InboxFilter.mentions.rawValue, "mentions")
    }

    func testInboxFilterAdmits() {
        XCTAssertTrue(InboxFilter.all.admits(.reviewRequest))
        XCTAssertTrue(InboxFilter.all.admits(.openQuestion))
        XCTAssertTrue(InboxFilter.reviews.admits(.reviewRequest))
        XCTAssertFalse(InboxFilter.reviews.admits(.openQuestion))
        XCTAssertTrue(InboxFilter.questions.admits(.openQuestion))
        XCTAssertFalse(InboxFilter.questions.admits(.reviewRequest))
        XCTAssertTrue(InboxFilter.mentions.admits(.mention))
        XCTAssertFalse(InboxFilter.mentions.admits(.commentOnMyWork))
    }

    func testInboxItemEquatable() {
        let a = InboxItem(id: "x", kind: .reviewRequest, severity: .warn, title: "T",
                          sourceMeta: "M", sourceURL: URL(string: "https://x.com")!,
                          aggregatedCount: 1, createdAtMs: 1)
        let b = InboxItem(id: "x", kind: .reviewRequest, severity: .warn, title: "T",
                          sourceMeta: "M", sourceURL: URL(string: "https://x.com")!,
                          aggregatedCount: 1, createdAtMs: 1)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.id, "x")
    }

    func testInboxSeveritySortRank() {
        XCTAssertLessThan(InboxSeverity.danger.sortRank, InboxSeverity.warn.sortRank)
        XCTAssertLessThan(InboxSeverity.warn.sortRank, InboxSeverity.muted.sortRank)
    }

    func testTodayMetricsEmpty() {
        let e = TodayMetrics.empty
        XCTAssertEqual(e.focusedMin, 0)
        XCTAssertEqual(e.aiRatio, 0)
        XCTAssertEqual(e.sessionsCount, 0)
        XCTAssertEqual(e.switchCount, 0)
        XCTAssertEqual(e.commitsCount, 0)
        XCTAssertTrue(e.surfacePills.isEmpty)
    }

    func testSurfacePillIdentifiable() {
        let p = SurfacePill(id: "xcode", label: "Xcode", count: 5)
        XCTAssertEqual(p.id, "xcode")
        XCTAssertEqual(p.label, "Xcode")
        XCTAssertEqual(p.count, 5)
    }
}
