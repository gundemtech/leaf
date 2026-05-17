import XCTest
@testable import LeafCore

final class LayerBProviderTests: XCTestCase {
    func test_allCases_haveExpectedOrder() {
        XCTAssertEqual(LayerBProvider.allCases, [.linear, .github, .slack])
    }

    func test_displayName_linear() {
        XCTAssertEqual(LayerBProvider.linear.displayName, "Linear")
    }

    func test_displayName_github() {
        XCTAssertEqual(LayerBProvider.github.displayName, "GitHub")
    }

    func test_displayName_slack() {
        XCTAssertEqual(LayerBProvider.slack.displayName, "Slack")
    }

    func test_rawValue_isSnakeCaseProviderName() {
        XCTAssertEqual(LayerBProvider.linear.rawValue, "linear")
        XCTAssertEqual(LayerBProvider.github.rawValue, "github")
        XCTAssertEqual(LayerBProvider.slack.rawValue, "slack")
    }

    func test_id_equalsRawValue() {
        XCTAssertEqual(LayerBProvider.linear.id, "linear")
        XCTAssertEqual(LayerBProvider.github.id, "github")
        XCTAssertEqual(LayerBProvider.slack.id, "slack")
    }

    func test_hashable_distinct() {
        let set: Set<LayerBProvider> = [.linear, .github, .slack, .linear]
        XCTAssertEqual(set.count, 3)
    }
}
