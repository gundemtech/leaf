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
        // C-33 (T10): parity assertion for .alerts case added in T8 — guards
        // against accidental rename that would silently change persisted state.
        XCTAssertEqual(InboxFilter.alerts.rawValue, "alerts")
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

// MARK: - Track-9 T8: InboxKind 5 → 14 + InboxFilter .alerts chip
// See docs/superpowers/specs/2026-05-21-track-9-T8-inbox-feeder-expansion.md §4.3
extension InboxItemTests {

    func testInboxKindCount_14CasesUnderT8() {
        XCTAssertEqual(InboxKind.allCases.count, 14)
        // Existing 5 (order preserved)
        XCTAssertEqual(InboxKind.allCases[0], .reviewRequest)
        XCTAssertEqual(InboxKind.allCases[1], .commentOnMyWork)
        XCTAssertEqual(InboxKind.allCases[2], .mention)
        XCTAssertEqual(InboxKind.allCases[3], .openQuestion)
        XCTAssertEqual(InboxKind.allCases[4], .blocker)
        // T8 viable new (3)
        XCTAssertEqual(InboxKind.allCases[5], .buildFailed)
        XCTAssertEqual(InboxKind.allCases[6], .ciFailed)
        XCTAssertEqual(InboxKind.allCases[7], .liveMeeting)
        // T8 placeholder (6)
        XCTAssertEqual(InboxKind.allCases[8], .calInviteDeclined)
        XCTAssertEqual(InboxKind.allCases[9], .calUpcoming15min)
        XCTAssertEqual(InboxKind.allCases[10], .calConflict)
        XCTAssertEqual(InboxKind.allCases[11], .mailUnreadBucket)
        XCTAssertEqual(InboxKind.allCases[12], .reminderDueToday)
        XCTAssertEqual(InboxKind.allCases[13], .slackDM)
    }

    func testInboxFilterAdmits_5FilterMatrix() {
        // Table-driven: 5 filters × 14 kinds
        let filters = InboxFilter.allCases
        XCTAssertEqual(filters.count, 5)

        // .all admits everything
        for kind in InboxKind.allCases {
            XCTAssertTrue(InboxFilter.all.admits(kind), "\(InboxFilter.all) should admit \(kind)")
        }

        // .reviews admits only .reviewRequest
        for kind in InboxKind.allCases {
            XCTAssertEqual(InboxFilter.reviews.admits(kind), kind == .reviewRequest)
        }

        // .questions admits only .openQuestion
        for kind in InboxKind.allCases {
            XCTAssertEqual(InboxFilter.questions.admits(kind), kind == .openQuestion)
        }

        // .mentions admits only .mention
        for kind in InboxKind.allCases {
            XCTAssertEqual(InboxFilter.mentions.admits(kind), kind == .mention)
        }

        // .alerts admits .buildFailed + .ciFailed + .liveMeeting only
        let alertKinds: Set<InboxKind> = [.buildFailed, .ciFailed, .liveMeeting]
        for kind in InboxKind.allCases {
            XCTAssertEqual(InboxFilter.alerts.admits(kind), alertKinds.contains(kind))
        }
    }
}
