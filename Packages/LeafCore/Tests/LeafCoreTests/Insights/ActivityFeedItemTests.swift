import XCTest

@testable import LeafCore

final class ActivityFeedItemTests: XCTestCase {
    func test_roundTrip_codable() throws {
        let item = ActivityFeedItem(
            ts: 1_700_000_000_000,
            source: .github,
            eventKind: "gh_pr_merged",
            actorDisplay: "anton",
            actorIsMe: false,
            targetTitle: "Add Track-11 substrate",
            targetRef: "PR#142",
            repoHint: "leaf",
            sourceURL: URL(string: "https://github.com/gundemtech/leaf/pull/142")
        )
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(ActivityFeedItem.self, from: data)
        XCTAssertEqual(decoded, item)
    }

    func test_sinceSource_allCases_fixedOrder() {
        XCTAssertEqual(SinceSource.allCases, [.linear, .github, .slack, .detection])
    }

    func test_sinceSource_rawValue_stable() {
        XCTAssertEqual(SinceSource.linear.rawValue, "linear")
        XCTAssertEqual(SinceSource.github.rawValue, "github")
        XCTAssertEqual(SinceSource.slack.rawValue, "slack")
        XCTAssertEqual(SinceSource.detection.rawValue, "detection")
    }
}
