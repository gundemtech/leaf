import XCTest
@testable import LeafCore

final class AttentionGranularityPolicyTests: XCTestCase {
    private let policy = DefaultAttentionGranularityPolicy()

    func testKnownDevBundle_isL3() {
        XCTAssertEqual(policy.maxGranularity(for: "com.apple.dt.Xcode"), .l3)
    }

    func testKnownBrowseBundle_isL3() {
        XCTAssertEqual(policy.maxGranularity(for: "com.apple.Safari"), .l3)
    }

    func testKnownCommunicationBundle_isL3() {
        XCTAssertEqual(policy.maxGranularity(for: "com.tinyspeck.slackmacgap"), .l3)
    }

    func testKnownDesignBundle_isL3() {
        XCTAssertEqual(policy.maxGranularity(for: "com.figma.Desktop"), .l3)
    }

    func testUnknownBundle_isL1() {
        XCTAssertEqual(policy.maxGranularity(for: "io.example.unknown"), .l1)
    }

    func testEmptyBundle_isL1() {
        XCTAssertEqual(policy.maxGranularity(for: ""), .l1)
    }

    func testRawValuesAreStable() {
        // External serialization (DB / config) полагается на raw int. Защита от
        // случайного reorder enum cases.
        XCTAssertEqual(AttentionGranularityLevel.l1.rawValue, 1)
        XCTAssertEqual(AttentionGranularityLevel.l2.rawValue, 2)
        XCTAssertEqual(AttentionGranularityLevel.l3.rawValue, 3)
        XCTAssertEqual(AttentionGranularityLevel.l4.rawValue, 4)
        XCTAssertEqual(AttentionGranularityLevel.l5.rawValue, 5)
    }
}
