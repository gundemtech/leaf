import XCTest

@testable import LeafCore

final class DecisionTests: XCTestCase {
    func testMemberwiseInit() {
        let d = Decision(
            id: 1,
            excerpt: "Use SQLite WAL for cross-process",
            topicKeywords: ["sqlite", "wal", "cross-process"],
            confidence: 0.87,
            detectedAtMs: 1_700_000_000_000,
            sourceEventId: 42
        )
        XCTAssertEqual(d.id, 1)
        XCTAssertEqual(d.topicKeywords.count, 3)
        XCTAssertEqual(d.sourceEventId, 42)
    }

    func testEmptyTopicKeywordsAllowed() {
        let d = Decision(
            id: 1,
            excerpt: "Pure intention",
            topicKeywords: [],
            confidence: 0.5,
            detectedAtMs: 0,
            sourceEventId: nil
        )
        XCTAssertEqual(d.topicKeywords, [])
    }

    func testConfidenceBoundary_zeroAndOne() {
        let zero = Decision(
            id: 1, excerpt: "x", topicKeywords: [],
            confidence: 0.0, detectedAtMs: 0, sourceEventId: nil)
        let one = Decision(
            id: 2, excerpt: "x", topicKeywords: [],
            confidence: 1.0, detectedAtMs: 0, sourceEventId: nil)
        XCTAssertEqual(zero.confidence, 0.0)
        XCTAssertEqual(one.confidence, 1.0)
    }

    func testEquatable_idDifferenceUnequal() {
        let a = Decision(
            id: 1, excerpt: "x", topicKeywords: [],
            confidence: 0.5, detectedAtMs: 0, sourceEventId: nil)
        let b = Decision(
            id: 2, excerpt: "x", topicKeywords: [],
            confidence: 0.5, detectedAtMs: 0, sourceEventId: nil)
        XCTAssertNotEqual(a, b)
    }

    func testHashable_sameValuesEqualHash() {
        let a = Decision(
            id: 1, excerpt: "x", topicKeywords: ["t"],
            confidence: 0.5, detectedAtMs: 0, sourceEventId: nil)
        let b = Decision(
            id: 1, excerpt: "x", topicKeywords: ["t"],
            confidence: 0.5, detectedAtMs: 0, sourceEventId: nil)
        XCTAssertEqual(Set([a, b]).count, 1)
    }

    func testSendableConformance() {
        let _: any Sendable = Decision(
            id: 1, excerpt: "x", topicKeywords: [],
            confidence: 0.5, detectedAtMs: 0, sourceEventId: nil
        )
    }
}
