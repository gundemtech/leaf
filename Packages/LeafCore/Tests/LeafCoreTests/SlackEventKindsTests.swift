import XCTest
@testable import LeafCore

final class SlackEventKindsTests: XCTestCase {
    func testAllCasesCount27() {
        XCTAssertEqual(SlackEventKindKey.allCases.count, 27,
                       "8 existing + 13 warm + 6 cold = 27")
    }

    func testLegacyRenamedCount2() {
        XCTAssertEqual(SlackEventKindKey.legacyRenamed.count, 2,
                       "Only 2 baseline kinds need M017 rename")
    }

    func testLegacyRenamedMembership() {
        XCTAssertTrue(SlackEventKindKey.legacyRenamed.contains(.slackMessageAuthored))
        XCTAssertTrue(SlackEventKindKey.legacyRenamed.contains(.slackHuddleStateChange))
    }

    func testBodyBearingCount4() {
        XCTAssertEqual(SlackEventKindKey.bodyBearing.count, 4,
                       "Canvas (2) + Bookmark (2) titles per ADR-010 §6 amendment")
    }

    func testBodyBearingMembership() {
        let expected: Set<SlackEventKindKey> = [
            .slackCanvasCreated, .slackCanvasEdited,
            .slackBookmarkAdded, .slackBookmarkRemoved
        ]
        XCTAssertEqual(SlackEventKindKey.bodyBearing, expected)
    }

    func testAllRawValuesStartWithSlackPrefix() {
        for kind in SlackEventKindKey.allCases {
            XCTAssertTrue(kind.rawValue.hasPrefix("slack_"),
                          "Raw value '\(kind.rawValue)' missing canonical 'slack_' prefix")
        }
    }

    func testAllRawValuesUnique() {
        let raws = Set(SlackEventKindKey.allCases.map(\.rawValue))
        XCTAssertEqual(raws.count, SlackEventKindKey.allCases.count,
                       "Duplicate rawValue across cases")
    }

    // Scope-catalogue tests moved to `SlackScopesServiceTests` in Task 8 —
    // catalogues now live on `SlackScopesService`, not `SlackEventKindKey`.
}
