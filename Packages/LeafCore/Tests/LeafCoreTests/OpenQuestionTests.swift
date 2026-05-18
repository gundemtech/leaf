import XCTest

@testable import LeafCore

final class OpenQuestionTests: XCTestCase {
    func testMemberwiseInit_openWithRef() {
        let q = OpenQuestion(
            id: 1,
            excerpt: "Should we use AES-GCM or ChaCha20?",
            alternatives: ["AES-GCM", "ChaCha20"],
            contextRef: .linearIssue(ref: "LEAF-142"),
            openedAtMs: 1_700_000_000_000,
            resolvedAtMs: nil,
            resolvedBySourceEventId: nil
        )
        XCTAssertEqual(q.id, 1)
        XCTAssertEqual(q.alternatives.count, 2)
        XCTAssertNil(q.resolvedAtMs)
    }

    func testIsOpen_resolvedAtMsNil() {
        let open = OpenQuestion(
            id: 1, excerpt: "x", alternatives: [],
            contextRef: nil, openedAtMs: 0,
            resolvedAtMs: nil, resolvedBySourceEventId: nil)
        XCTAssertNil(open.resolvedAtMs)
    }

    func testIsResolved_resolvedAtMsSet() {
        let closed = OpenQuestion(
            id: 1, excerpt: "x", alternatives: [],
            contextRef: nil, openedAtMs: 0,
            resolvedAtMs: 9999, resolvedBySourceEventId: 42)
        XCTAssertEqual(closed.resolvedAtMs, 9999)
        XCTAssertEqual(closed.resolvedBySourceEventId, 42)
    }

    func testContextRef_nilAllowed() {
        let q = OpenQuestion(
            id: 1, excerpt: "x", alternatives: [],
            contextRef: nil, openedAtMs: 0,
            resolvedAtMs: nil, resolvedBySourceEventId: nil)
        XCTAssertNil(q.contextRef)
    }

    func testContextRef_slackThreadRoundTrip() {
        let q = OpenQuestion(
            id: 1, excerpt: "x", alternatives: [],
            contextRef: .slackThread(ts: "1700000000.000100"),
            openedAtMs: 0, resolvedAtMs: nil, resolvedBySourceEventId: nil)
        if case .slackThread(let ts) = q.contextRef {
            XCTAssertEqual(ts, "1700000000.000100")
        } else {
            XCTFail("Expected slackThread case")
        }
    }

    func testHashableAcrossOpenResolved() {
        let open = OpenQuestion(
            id: 1, excerpt: "x", alternatives: [],
            contextRef: nil, openedAtMs: 0,
            resolvedAtMs: nil, resolvedBySourceEventId: nil)
        let resolved = OpenQuestion(
            id: 1, excerpt: "x", alternatives: [],
            contextRef: nil, openedAtMs: 0,
            resolvedAtMs: 100, resolvedBySourceEventId: nil)
        XCTAssertNotEqual(open, resolved)
        XCTAssertEqual(Set([open, resolved]).count, 2)
    }

    func testSendableConformance() {
        let _: any Sendable = OpenQuestion(
            id: 1, excerpt: "x", alternatives: [],
            contextRef: nil, openedAtMs: 0,
            resolvedAtMs: nil, resolvedBySourceEventId: nil
        )
    }
}
