import XCTest

@testable import LeafCore

final class AttentionGranularityPolicyTests: XCTestCase {
    func testEmptyClassifier_anyBundle_isL1() {
        // Empty classifier → всё .other → L1 (conservative default).
        let policy = DefaultAttentionGranularityPolicy(classifier: EmptyAppCategoryClassifier())
        XCTAssertEqual(policy.maxGranularity(for: "com.apple.dt.Xcode"), .l1)
        XCTAssertEqual(policy.maxGranularity(for: "com.apple.Safari"), .l1)
        XCTAssertEqual(policy.maxGranularity(for: ""), .l1)
    }

    func testStubClassifier_devBundle_isL3() {
        let stub = StubClassifier(devBundles: ["test.dev"])
        let policy = DefaultAttentionGranularityPolicy(classifier: stub)
        XCTAssertEqual(policy.maxGranularity(for: "test.dev"), .l3)
    }

    func testStubClassifier_browseBundle_isL3() {
        let stub = StubClassifier(browseBundles: ["test.browse"])
        let policy = DefaultAttentionGranularityPolicy(classifier: stub)
        XCTAssertEqual(policy.maxGranularity(for: "test.browse"), .l3)
    }

    func testStubClassifier_communicationBundle_isL3() {
        let stub = StubClassifier(communicationBundles: ["test.comm"])
        let policy = DefaultAttentionGranularityPolicy(classifier: stub)
        XCTAssertEqual(policy.maxGranularity(for: "test.comm"), .l3)
    }

    func testStubClassifier_designBundle_isL3() {
        let stub = StubClassifier(designBundles: ["test.design"])
        let policy = DefaultAttentionGranularityPolicy(classifier: stub)
        XCTAssertEqual(policy.maxGranularity(for: "test.design"), .l3)
    }

    func testStubClassifier_otherBundle_isL1() {
        let stub = StubClassifier()
        let policy = DefaultAttentionGranularityPolicy(classifier: stub)
        XCTAssertEqual(policy.maxGranularity(for: "io.example.unknown"), .l1)
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

private struct StubClassifier: AppCategoryClassifier {
    var devBundles: Set<String> = []
    var browseBundles: Set<String> = []
    var communicationBundles: Set<String> = []
    var designBundles: Set<String> = []

    func category(for bundleID: String) -> AppCategory {
        if devBundles.contains(bundleID) { return .dev }
        if browseBundles.contains(bundleID) { return .browse }
        if communicationBundles.contains(bundleID) { return .communication }
        if designBundles.contains(bundleID) { return .design }
        return .other
    }
}
